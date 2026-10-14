import Foundation

struct MonitoringResult: Sendable {
    let date: Date
    let thermal: ThermalLevel
    let cpu: Double?
    let processes: [AppProcess]
    let loadAverage: Double
    let totalProcessCount: Int
    let readableProcessCount: Int
    let ownCPU: Double
    let ownMemory: UInt64
    let elapsedMilliseconds: Double
    var timings = SamplingTimings()
}

actor MonitoringWorker {
    private var previous: Snapshot?
    private var analyzer = AnalysisEngine()
    private var metadataCache: [ProcessIdentity: (path: String, value: AppMetadata)] = [:]

    func reset() {
        previous = nil
        analyzer.resetContinuousEvidence()
        metadataCache.removeAll(keepingCapacity: true)
    }

    func resetBaseline() { previous = nil }

    func sample(context: AnalysisContext, limited: Set<ProcessIdentity>) -> MonitoringResult {
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = SnapshotProvider.capture()
        let captured = ProcessInfo.processInfo.systemUptime
        let deltas = previous.map { DeltaCalculator.processes(previous: $0, current: snapshot) } ?? []
        let cpu = previous.flatMap { DeltaCalculator.hostCPU(previous: $0, current: snapshot) }
        let calculated = ProcessInfo.processInfo.systemUptime
        var enrichedContext = context
        enrichedContext.metadata = metadata(for: deltas, context: context)
        let enriched = ProcessInfo.processInfo.systemUptime
        // A deliberately reset baseline is not a failed observation. Preserve
        // prior evidence until the first actual interval; real missing frames
        // still reach the analyzer and break their continuous high-CPU run.
        let rows = previous == nil ? [] : analyzer.analyze(
            deltas: deltas, at: snapshot.date, thermal: snapshot.thermal, limited: limited,
            ownPID: getpid(), context: enrichedContext, rawProcesses: snapshot.processes)
        let analyzed = ProcessInfo.processInfo.systemUptime
        previous = snapshot
        return MonitoringResult(date: snapshot.date, thermal: snapshot.thermal, cpu: cpu,
                                processes: rows, loadAverage: NativeSampler.loadAverage() ?? 0,
                                totalProcessCount: snapshot.processes.count,
                                readableProcessCount: snapshot.processes.filter { $0.cpuTimeNanoseconds != nil }.count,
                                ownCPU: deltas.first { $0.identity.pid == getpid() }?.cpuPercent ?? 0,
                                ownMemory: NativeSampler.selfFootprint()
                                    ?? snapshot.processes.first { $0.identity.pid == getpid() }?.residentBytes ?? 0,
                                elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                timings: SamplingTimings(snapshotMilliseconds: (captured - started) * 1000,
                                    deltaMilliseconds: (calculated - captured) * 1000,
                                    metadataMilliseconds: (enriched - calculated) * 1000,
                                    analysisMilliseconds: (analyzed - enriched) * 1000))
    }

    func deepScan(context: AnalysisContext, limited: Set<ProcessIdentity>) async -> DeepScanResult {
        let capture = await TopSampler.capture()
        let deltas = capture.deltas
        guard !Task.isCancelled else { return DeepScanResult(processes: [], succeeded: false) }
        var transient = AnalysisEngine()
        var enrichedContext = context
        enrichedContext.metadata = metadata(for: deltas, context: context)
        let processes = transient.analyze(deltas: deltas, at: Date(), thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                                         limited: limited, ownPID: getpid(), context: enrichedContext)
        return DeepScanResult(processes: processes, succeeded: capture.succeeded)
    }

    private func metadata(for deltas: [ProcessDelta], context: AnalysisContext) -> [ProcessIdentity: AppMetadata] {
        var values: [ProcessIdentity: AppMetadata] = [:]
        values.reserveCapacity(deltas.count)
        var roots = Dictionary(context.runningMetadata.values.compactMap { metadata -> (String, AppMetadata)? in
            guard let root = metadata.bundleRoot, AppResolver.appRoot(from: root) == root else { return nil }
            return (root, metadata)
        }, uniquingKeysWith: { first, _ in first })
        for delta in deltas {
            if let cached = metadataCache[delta.identity], cached.path == delta.path {
                values[delta.identity] = cached.value
            } else {
                let resolved: AppMetadata
                if let root = AppResolver.appRoot(from: delta.path) {
                    resolved = roots[root] ?? AppResolver.metadata(for: delta)
                    roots[root] = resolved
                } else {
                    resolved = context.runningMetadata[delta.identity.pid] ?? AppResolver.metadata(for: delta)
                }
                metadataCache[delta.identity] = (delta.path, resolved)
                values[delta.identity] = resolved
            }
        }
        if metadataCache.count > 2_048 {
            let keep = Set(deltas.map(\.identity))
            metadataCache = metadataCache.filter { keep.contains($0.key) }
        }
        return values
    }
}

struct DeepScanResult: Sendable {
    let processes: [AppProcess]
    let succeeded: Bool
}

struct ScanAccumulator {
    struct Entry {
        var latest: AppProcess
        var cpuSeconds: Double = 0
        var observedSeconds: Double = 0
        var peak: Double = 0
    }
    private(set) var entries: [String: Entry] = [:]
    private(set) var hostCPUSeconds = 0.0
    private(set) var duration = 0.0
    mutating func append(_ result: MonitoringResult, seconds: Double) {
        guard seconds > 0, seconds <= 65, let cpu = result.cpu else { return }
        duration += seconds
        hostCPUSeconds += cpu * seconds
        for process in result.processes where process.cpuPercent >= 0.1 || entries[process.groupKey] != nil {
            let key = process.groupKey
            var entry = entries[key] ?? Entry(latest: process)
            // Preserve stronger sustained evidence, including a task that finishes before the last frame.
            if process.risk >= entry.latest.risk { entry.latest = process }
            entry.cpuSeconds += process.cpuPercent * seconds
            entry.observedSeconds += seconds
            entry.peak = max(entry.peak, process.cpuPercent)
            entries[key] = entry
        }
        if entries.count > 300 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.cpuSeconds > $1.value.cpuSeconds }.prefix(300).map { ($0.key, $0.value) })
        }
    }
    var meanHostCPU: Double { duration > 0 ? hostCPUSeconds / duration : 0 }
    var contributors: [AppProcess] {
        entries.values.map { entry in
            let mean = entry.cpuSeconds / max(duration, 0.001)
            return entry.latest.withCPU(mean, evidence: ["观察期平均 \(mean.percentText)；峰值 \(entry.peak.percentText)",
                "累计观察约 \(Int(entry.observedSeconds)) 秒"] + entry.latest.evidence.filter { !$0.contains("当前占用") && !$0.contains("合计占用") })
        }.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
