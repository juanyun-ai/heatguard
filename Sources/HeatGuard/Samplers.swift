import AppKit
import Darwin
import Foundation
import HeatGuardNative

enum NativeSampler {
    static func hostTicks() -> HostTicks? {
        var ticks = HGHostCPUTicks()
        guard hg_read_host_cpu_ticks(&ticks) == 1 else { return nil }
        return HostTicks(user: ticks.user, system: ticks.system, idle: ticks.idle, nice: ticks.nice)
    }

    static func processes() -> [RawProcessSample] {
        let capacity = max(2_048, Int(proc_listallpids(nil, 0)) + 256)
        let pointer = UnsafeMutablePointer<HGProcessSample>.allocate(capacity: capacity)
        pointer.initialize(repeating: HGProcessSample(), count: capacity)
        defer {
            pointer.deinitialize(count: capacity)
            pointer.deallocate()
        }

        let count = Int(hg_collect_processes(pointer, Int32(capacity)))
        guard count > 0 else { return [] }

        return (0..<count).compactMap { decode(pointer[$0]) }
    }

    /// Read one process for action validation without another full process scan.
    static func process(pid: pid_t) -> RawProcessSample? {
        var sample = HGProcessSample()
        guard hg_read_process(pid, &sample) == 1 else { return nil }
        return decode(sample)
    }

    private static func decode(_ sample: HGProcessSample) -> RawProcessSample? {
        let name = withUnsafeBytes(of: sample.name) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let path = withUnsafeBytes(of: sample.path) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let mask = UInt8(sample.metrics_available)
        let hasCPU = (mask & UInt8(HG_METRICS_CPU)) != 0
        let hasWakeups = (mask & UInt8(HG_METRICS_WAKEUPS)) != 0
        let hasDisk = (mask & UInt8(HG_METRICS_DISK)) != 0
        let hasResident = (mask & UInt8(HG_METRICS_RESIDENT)) != 0
        return RawProcessSample(
            identity: ProcessIdentity(pid: sample.pid, startAbstime: sample.process_start_abstime),
            parentPID: sample.parent_pid,
            uid: sample.uid,
            name: name.isEmpty ? "PID \(sample.pid)" : name,
            path: path,
            cpuTimeNanoseconds: hasCPU ? sample.user_time_ns &+ sample.system_time_ns : nil,
            interruptWakeups: hasWakeups ? sample.interrupt_wakeups : nil,
            packageWakeups: hasWakeups ? sample.package_idle_wakeups : nil,
            diskBytes: hasDisk ? sample.disk_read_bytes &+ sample.disk_write_bytes : nil,
            residentBytes: hasResident ? sample.resident_bytes : nil,
            processStatus: sample.process_status
        )
    }

    static func loadAverage() -> Double? {
        var value = 0.0
        return hg_read_load_average(&value) == 1 ? value : nil
    }

    static func selfFootprint() -> UInt64? {
        var bytes: UInt64 = 0
        return hg_read_self_footprint(&bytes) == 1 ? bytes : nil
    }

    /// Read scheduler metadata on demand after an explicit policy action.
    /// This is deliberately not part of `processes()` or `process(pid:)`:
    /// normal monitoring must remain a cheap CPU/IO sampler.
    static func processScheduling(pid: pid_t) -> (policy: Int, priority: Int, maxPriority: Int,
                                                    threadCount: Int, readableThreads: Int,
                                                    backgroundThreads: Int)? {
        var scheduling = HGProcessScheduling()
        guard hg_read_process_scheduling(pid, &scheduling) == 1 else { return nil }
        return (Int(scheduling.policy), Int(scheduling.priority), Int(scheduling.max_priority),
                Int(scheduling.thread_count), Int(scheduling.readable_threads),
                Int(scheduling.background_threads))
    }
}

struct Snapshot: Sendable {
    let date: Date
    /// Monotonic uptime is preferred for deltas; Date remains for display and persistence.
    let uptime: TimeInterval
    let hostTicks: HostTicks?
    let processes: [RawProcessSample]
    let thermal: ThermalLevel

    init(date: Date, uptime: TimeInterval = 0, hostTicks: HostTicks?, processes: [RawProcessSample], thermal: ThermalLevel) {
        self.date = date
        self.uptime = uptime
        self.hostTicks = hostTicks
        self.processes = processes
        self.thermal = thermal
    }
}

enum SnapshotProvider {
    static func capture() -> Snapshot {
        Snapshot(
            date: Date(),
            uptime: ProcessInfo.processInfo.systemUptime,
            hostTicks: NativeSampler.hostTicks(),
            processes: NativeSampler.processes(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState)
        )
    }
}

enum DeltaCalculator {
    static func hostCPU(previous: HostTicks?, current: HostTicks?) -> Double? {
        guard let previous, let current,
              current.total >= previous.total,
              current.busy >= previous.busy else { return nil }
        let total = current.total - previous.total
        let busy = current.busy - previous.busy
        guard total > 0, busy <= total else { return nil }
        return Double(busy) / Double(total) * 100
    }

    static func hostCPU(previous: Snapshot, current: Snapshot) -> Double? {
        guard sampleDuration(previous: previous, current: current) != nil else { return nil }
        return hostCPU(previous: previous.hostTicks, current: current.hostTicks)
    }

    /// Every derived metric uses the same valid interval. Sleep, clock changes,
    /// and an unchanged baseline must not become a fabricated zero-load sample.
    static func sampleDuration(previous: Snapshot, current: Snapshot) -> TimeInterval? {
        let wallDuration = current.date.timeIntervalSince(previous.date)
        let monotonicDuration = current.uptime > previous.uptime ? current.uptime - previous.uptime : 0
        let duration = monotonicDuration > 0 ? monotonicDuration : wallDuration
        guard duration > 0.2, duration < 90 else { return nil }
        // Uptime and wall time diverge across sleep or a system-clock change.
        if monotonicDuration > 0 && abs(wallDuration - duration) > 5 { return nil }
        return duration
    }

    static func processes(previous: Snapshot, current: Snapshot) -> [ProcessDelta] {
        guard let duration = sampleDuration(previous: previous, current: current) else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.identity, $0) })
        return current.processes.compactMap { sample in
            guard let before = old[sample.identity],
                  let currentCPU = sample.cpuTimeNanoseconds,
                  let oldCPU = before.cpuTimeNanoseconds,
                  currentCPU >= oldCPU else { return nil }

            let cpu = Double(currentCPU - oldCPU) / 1_000_000_000 / duration * 100
            let wakeups = delta(current: sample.interruptWakeups, previous: before.interruptWakeups, duration: duration)
                + delta(current: sample.packageWakeups, previous: before.packageWakeups, duration: duration)
            let disk = delta(current: sample.diskBytes, previous: before.diskBytes, duration: duration)
            let wakeupsAvailable = sample.interruptWakeups != nil && before.interruptWakeups != nil
                && sample.packageWakeups != nil && before.packageWakeups != nil
            let diskAvailable = sample.diskBytes != nil && before.diskBytes != nil

            return ProcessDelta(
                identity: sample.identity,
                parentPID: sample.parentPID,
                uid: sample.uid,
                name: sample.name,
                path: sample.path,
                cpuPercent: cpu.isFinite ? max(0, cpu) : 0,
                wakeupsPerSecond: wakeups,
                diskBytesPerSecond: disk,
                residentBytes: sample.residentBytes ?? 0,
                sampleDuration: duration,
                wakeupsAvailable: wakeupsAvailable,
                diskAvailable: diskAvailable
            )
        }
    }

    private static func delta(current: UInt64?, previous: UInt64?, duration: TimeInterval) -> Double {
        guard let current, let previous, current >= previous else { return 0 }
        return Double(current - previous) / duration
    }
}

struct AppMetadata: Sendable {
    let displayName: String
    let bundleIdentifier: String?
    let bundleRoot: String?
}

enum AppResolver {
    static func metadata(for delta: ProcessDelta) -> AppMetadata {
        // Resolve the outermost .app first so browser/Electron helper bundles are
        // attributed to the application the user recognizes.
        if let root = appRoot(from: delta.path) {
            let url = URL(fileURLWithPath: root)
            let bundle = Bundle(url: url)
            return AppMetadata(
                displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundle?.bundleIdentifier,
                bundleRoot: root
            )
        }

        return AppMetadata(displayName: delta.name, bundleIdentifier: nil, bundleRoot: nil)
    }

    static func appRoot(from path: String) -> String? {
        let bytes = path.utf8
        // ASCII paths need no Unicode case folding or lowercased allocation.
        // Keep Foundation's exact comparison semantics for every non-ASCII
        // input; this function also handles user names and localized app names.
        if bytes.contains(where: { $0 >= 128 }) { return foundationAppRoot(from: path) }
        var dot = bytes.startIndex
        while dot < bytes.endIndex {
            if bytes[dot] == 46 {
                let a = bytes.index(after: dot)
                if a < bytes.endIndex, bytes[a] | 32 == 97 {
                    let p1 = bytes.index(after: a)
                    if p1 < bytes.endIndex, bytes[p1] | 32 == 112 {
                        let p2 = bytes.index(after: p1)
                        if p2 < bytes.endIndex, bytes[p2] | 32 == 112 {
                            let end = bytes.index(after: p2)
                            if end == bytes.endIndex { return path }
                            if bytes[end] == 47 { return String(path[..<end]) }
                        }
                    }
                }
            }
            dot = bytes.index(after: dot)
        }
        return nil
    }

    private static func foundationAppRoot(from path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else {
            return path.lowercased().hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.upperBound].dropLast())
    }

    static func appName(from path: String) -> String? {
        appRoot(from: path).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }
}
