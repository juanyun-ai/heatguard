import Foundation

/// Small Sendable context prepared by the UI actor before sampling. It keeps
/// AppKit lookups out of the hot path and makes foreground/protection choices
/// explicit and testable.
struct AnalysisContext: Sendable {
    var foregroundPID: pid_t?
    var foregroundBundleIdentifier: String?
    var metadata: [ProcessIdentity: AppMetadata]
    var protectedBundleIDs: Set<String>
    var mainApplicationPIDs: Set<pid_t>
    var runningMetadata: [pid_t: AppMetadata] = [:]

    init(
        foregroundPID: pid_t? = nil,
        foregroundBundleIdentifier: String? = nil,
        metadata: [ProcessIdentity: AppMetadata] = [:],
        protectedBundleIDs: Set<String> = [],
        mainApplicationPIDs: Set<pid_t> = []
    ) {
        self.foregroundPID = foregroundPID
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
        self.metadata = metadata
        self.protectedBundleIDs = protectedBundleIDs
        self.mainApplicationPIDs = mainApplicationPIDs
    }
}

struct ProcessHistory: Sendable {
    var firstSeen: Date
    var lastSeen: Date
    var highCPUSince: Date?
    var highFrames: Int
    var recentCPU: [Double]
    var identities: Set<ProcessIdentity> = []

    init(firstSeen: Date, lastSeen: Date, highCPUSince: Date? = nil, highFrames: Int = 0, recentCPU: [Double] = []) {
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.highCPUSince = highCPUSince
        self.highFrames = highFrames
        self.recentCPU = recentCPU
    }

    var highDuration: TimeInterval {
        guard let highCPUSince else { return 0 }
        return max(0, lastSeen.timeIntervalSince(highCPUSince))
    }
}

struct AnalysisEngine: Sendable {
    private(set) var history: [String: ProcessHistory] = [:]
    private let currentUID = getuid()
    private var staticFacts = StaticProcessFactsCache()

    private struct LineageMemory: Sendable {
        var verdict: ProcessAncestryGate.Verdict?
        var userProtections: [String: String] = [:]
        var lastSeen: Date
    }

    /// A detached child can outlive its IDE, terminal, or protected app. Keep
    /// that association only for the live PID/start identity and only in
    /// memory; it never becomes a persisted allow/deny rule.
    private var lineageMemory: [ProcessIdentity: LineageMemory] = [:]

    /// A sleep/wake or baseline reset invalidates measured CPU duration, not
    /// the known ownership of a still-identical task. The next frame checks
    /// current identities and current user rules before using this memory.
    mutating func resetContinuousEvidence() {
        history.removeAll(keepingCapacity: true)
        staticFacts = StaticProcessFactsCache()
    }

    /// Aggregate helpers into the user-facing application before scoring.
    /// Elevated/high needs repeated background evidence; a single hot frame is
    /// intentionally only a watch item.
    mutating func analyze(
        deltas: [ProcessDelta],
        at date: Date,
        thermal: ThermalLevel,
        limited: Set<ProcessIdentity>,
        ownPID: pid_t,
        context: AnalysisContext = AnalysisContext(),
        rawProcesses: [RawProcessSample]? = nil
    ) -> [AppProcess] {
        let current = Dictionary(grouping: deltas) { delta in
            Self.groupKey(for: delta, metadata: context.metadata[delta.identity])
        }
        let roots = Dictionary(context.runningMetadata.values.compactMap { metadata -> (String, AppMetadata)? in
            metadata.bundleRoot.map { ($0, metadata) }
        }, uniquingKeysWith: { first, _ in first })
        // Include ancestors with unreadable CPU counters: they still provide
        // identity/parent evidence. No extra native scans or shell processes.
        let seeds = rawProcesses.map { samples in samples.map {
            ProcessAncestryGate.Node(identity: $0.identity, parentPID: $0.parentPID,
                uid: $0.uid, name: $0.name, path: $0.path)
        } } ?? deltas.map {
            ProcessAncestryGate.Node(identity: $0.identity, parentPID: $0.parentPID,
                uid: $0.uid, name: $0.name, path: $0.path)
        }
        let parentPIDs = Dictionary(seeds.map { ($0.identity.pid, $0.parentPID) },
                                    uniquingKeysWith: { first, _ in first })
        let referencedParents = Set(parentPIDs.values)
        var nodes: [pid_t: ProcessAncestryGate.Node] = [:]
        // Leaf tasks are never looked up as ancestors. Retain the full edge
        // map for foreground checks but classify only referenced parents.
        for var node in seeds where referencedParents.contains(node.identity.pid) {
            let root = AppResolver.appRoot(from: node.path)
            node.bundleIdentifier = context.metadata[node.identity]?.bundleIdentifier
                ?? root.flatMap { roots[$0]?.bundleIdentifier }
            let facts = staticFacts.facts(identity: node.identity, name: node.name,
                path: node.path, bundleIdentifier: node.bundleIdentifier)
            node.protectedTask = facts.advice.protected
            node.excludedFromAutomatic = facts.excludesAutomaticProtection
            nodes[node.identity.pid] = node
        }
        var ancestry = SnapshotAncestryResolver(nodes: nodes, ownPID: ownPID,
            protectedKeys: context.protectedBundleIDs)
        let activeKeys = Set(current.keys)
        let activeIdentities = Set(seeds.map(\.identity))
        history = history.filter { date.timeIntervalSince($0.value.lastSeen) < 600 || activeKeys.contains($0.key) }
        for identity in Array(lineageMemory.keys) {
            guard var memory = lineageMemory[identity] else { continue }
            memory.userProtections = memory.userProtections.filter { context.protectedBundleIDs.contains($0.key) }
            // An actually observed live identity remains the same task even
            // after sleep, unreadable CPU counters, or a wall-clock edit.
            if activeIdentities.contains(identity) { memory.lastSeen = date }
            let age = date.timeIntervalSince(memory.lastSeen)
            if age < 0 || age >= 600 || (memory.verdict == nil && memory.userProtections.isEmpty) {
                lineageMemory.removeValue(forKey: identity)
            } else {
                lineageMemory[identity] = memory
            }
        }
        // An unreadable/missing frame is not evidence of continued work. Keep
        // the identity/history shell, but require a fresh continuous run.
        for key in Array(history.keys) where !activeKeys.contains(key) {
            history[key]?.highCPUSince = nil
            history[key]?.highFrames = 0
            history[key]?.recentCPU.removeAll(keepingCapacity: true)
        }

        return current.compactMap { key, members in
            makeAppProcess(key: key, members: members, at: date, thermal: thermal,
                           limited: limited, ownPID: ownPID, context: context,
                           parentPIDs: parentPIDs, ancestry: &ancestry)
        }
        .sorted {
            if $0.risk != $1.risk { return $0.risk > $1.risk }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.cpuPercent > $1.cpuPercent
        }
    }

    private mutating func makeAppProcess(
        key: String,
        members: [ProcessDelta],
        at date: Date,
        thermal: ThermalLevel,
        limited: Set<ProcessIdentity>,
        ownPID: pid_t,
        context: AnalysisContext,
        parentPIDs: [pid_t: pid_t],
        ancestry: inout SnapshotAncestryResolver
    ) -> AppProcess? {
        guard let representative = members.max(by: { $0.cpuPercent < $1.cpuPercent }) else { return nil }
        let identities = members.map(\.identity)
        let cpu = members.reduce(0) { $0 + $1.cpuPercent }
        let wakeups = members.reduce(0) { $0 + $1.wakeupsPerSecond }
        let disk = members.reduce(0) { $0 + $1.diskBytesPerSecond }
        let wakeupsAvailable = members.allSatisfy(\.wakeupsAvailable)
        let diskAvailable = members.allSatisfy(\.diskAvailable)
        let memory = members.reduce(UInt64(0)) { partial, item in
            partial.addingReportingOverflow(item.residentBytes).overflow ? UInt64.max : partial &+ item.residentBytes
        }
        let metadata = context.metadata[representative.identity] ?? AppResolver.metadata(for: representative)
        let bundleID = metadata.bundleIdentifier
        let foreground = identities.contains { identity in
            context.foregroundPID == identity.pid
        } || (bundleID != nil && bundleID == context.foregroundBundleIdentifier)
            || Self.hasForegroundAncestor(identities: identities, parentPIDs: parentPIDs,
                                          foregroundPID: context.foregroundPID)
        var isSystem = false
        for member in members {
            // Ownership remains a live fact; only deterministic classification
            // of unchanged identity/name/path/bundle fields is memoized.
            if member.uid != currentUID || staticFacts.facts(identity: member.identity,
                name: member.name, path: member.path,
                bundleIdentifier: context.metadata[member.identity]?.bundleIdentifier).isSystemPath {
                isSystem = true
                break
            }
        }
        let advice = staticFacts.facts(identity: representative.identity,
            name: representative.name, path: representative.path, bundleIdentifier: bundleID).advice
        let userProtected = context.protectedBundleIDs.contains(bundleID ?? metadata.bundleRoot ?? representative.path)
        let lineage = members.map { member -> ProcessAncestryGate.Verdict in
            let ancestryEvaluation = ancestry.evaluation(parentPID: member.parentPID)
            let currentVerdict = ancestryEvaluation.verdict
            var remembered = lineageMemory[member.identity]
            if let persistent = ancestryEvaluation.persistent {
                if remembered == nil { remembered = LineageMemory(verdict: persistent, lastSeen: date) }
                // Never weaken an observed intrinsically protected lineage
                // merely because the child moved beneath an ordinary tool.
                if case .protectedTask? = remembered?.verdict {} else { remembered?.verdict = persistent }
            }
            if !ancestryEvaluation.userProtections.isEmpty {
                if remembered == nil { remembered = LineageMemory(verdict: nil, lastSeen: date) }
                remembered?.userProtections.merge(ancestryEvaluation.userProtections) { _, new in new }
            }
            if var remembered {
                remembered.lastSeen = date
                lineageMemory[member.identity] = remembered
                if let key = remembered.userProtections.keys.min(), let name = remembered.userProtections[key] {
                    return .protectedTask(name)
                }
                // A missing/reparented ancestor is not allowed to erase a
                // previously observed important/protected association. A
                // live explicit verdict still wins over the remembered one.
                switch currentVerdict {
                case .clear, .unknown:
                    return remembered.verdict ?? currentVerdict
                case .importantTask:
                    if let verdict = remembered.verdict, case .protectedTask = verdict { return verdict }
                case .protectedTask:
                    break
                }
            }
            return currentVerdict
        }
        let inheritedProtection = lineage.compactMap(\.manualBlockReason).first
        let automaticContextBlockReason = lineage.compactMap(\.automaticBlockReason).first
        let structuralProtection = representative.identity.pid <= 1
            || identities.contains(where: { $0.startAbstime == 0 })
            || identities.contains(where: { $0.pid == ownPID })
            || members.contains(where: { $0.uid != currentUID })
            || isSystem
        let protected = structuralProtection || advice.protected || userProtected || foreground || inheritedProtection != nil
        let protectionReason: String? = {
            if identities.contains(where: { $0.pid == ownPID }) { return "这是温衡自身" }
            if foreground { return "当前正在前台使用" }
            if representative.identity.startAbstime == 0 { return "无法可靠核验进程启动身份" }
            if members.contains(where: { $0.uid != currentUID }) { return "属于系统或其他用户" }
            if isSystem { return "这是 macOS 系统组件" }
            if userProtected { return "用户标记为受保护应用" }
            if advice.protected { return advice.explanation }
            if let inheritedProtection { return inheritedProtection }
            if representative.identity.pid <= 1 { return "系统关键进程" }
            return nil
        }()

        var record = history[key] ?? ProcessHistory(firstSeen: date, lastSeen: date)
        // Foreground work, a sampling gap, or a new instance cannot supply
        // evidence for a continuous background run.
        if foreground || date.timeIntervalSince(record.lastSeen) > 75
            || (!record.identities.isEmpty && record.identities.isDisjoint(with: identities)) {
            record.highCPUSince = nil
            record.highFrames = 0
            record.recentCPU.removeAll(keepingCapacity: true)
        }
        record.identities = Set(identities)
        record.lastSeen = date
        record.recentCPU.append(cpu)
        if record.recentCPU.count > 24 { record.recentCPU.removeFirst(record.recentCPU.count - 24) }
        if cpu >= 35 && !foreground {
            record.highCPUSince = record.highCPUSince ?? date
            record.highFrames += 1
        } else {
            record.highCPUSince = nil
            record.highFrames = 0
        }
        history[key] = record

        let averageCPU = record.recentCPU.reduce(0, +) / Double(max(record.recentCPU.count, 1))
        let sustained = record.highDuration >= 60 && record.highFrames >= 3 && !foreground
        let confidence = confidenceFor(cpu: cpu, averageCPU: averageCPU, duration: record.highDuration,
                                       highFrames: record.highFrames, wakeups: wakeups, thermal: thermal,
                                       protected: protected)
        let risk: RiskLevel
        if !protected && sustained && cpu >= 180 {
            risk = .high
        } else if !protected && sustained && cpu >= 35 {
            risk = .elevated
        } else if cpu >= 20 || wakeups >= 100 || (thermal >= .serious && cpu >= 10) {
            risk = .watch
        } else {
            risk = .normal
        }

        var evidence = [
            "当前占用 " + cpu.percentText + "（" + String(format: "%.2f 核", cpu / 100) + "）",
            "近期均值 " + averageCPU.percentText
        ]
        if record.highDuration >= 5 { evidence.append("连续高占用约 " + String(Int(record.highDuration)) + " 秒") }
        evidence.append(foreground ? "当前正在前台使用" : "目前不在前台")
        if wakeups >= 50 { evidence.append("每秒约 " + String(Int(wakeups)) + " 次唤醒") }
        if ActivitySignature.lowIOHighCPU(cpuPercent: cpu, diskBytesPerSecond: disk,
                                          wakeupsPerSecond: wakeups,
                                          diskAvailable: diskAvailable,
                                          wakeupsAvailable: wakeupsAvailable) {
            evidence.append("高 CPU 但磁盘/唤醒较低，可能是空转或纯计算")
        } else if cpu >= 80 && ActivitySignature.highIODuringCPU(
            diskBytesPerSecond: disk, wakeupsPerSecond: wakeups) {
            evidence.append("高 CPU 同时伴随明显磁盘/唤醒活动，更像有效任务")
        }
        if members.count > 1 { evidence.append("已合并 " + String(members.count) + " 个辅助进程") }
        if protected, let protectionReason { evidence.append("受保护：" + protectionReason) }
        if !protected, let automaticContextBlockReason { evidence.append(automaticContextBlockReason) }
        if sustained && !protected { evidence.append("已满足至少 60 秒、3 个采样窗口的持续证据") }

        let recommendation: String
        if identities.contains(where: { $0.pid == ownPID }) {
            recommendation = "无需处理。温衡会在后台自动降低采样频率。"
        } else if protected {
            recommendation = advice.protected ? advice.recommendation : "温衡不会改动前台、系统或受保护进程；先确认对应任务是否正在工作。"
        } else if risk >= .elevated {
            let activityHint = ActivitySignature.lowIOHighCPU(
                cpuPercent: cpu, diskBytesPerSecond: disk, wakeupsPerSecond: wakeups,
                diskAvailable: diskAvailable, wakeupsAvailable: wakeupsAvailable)
                ? "高 CPU 但低 I/O，可能是空转或纯计算；" : ""
            recommendation = activityHint + "先查看任务是否仍有用；确认可停止时优先正常退出，无响应时再确认强制结束。降低调度优先级并非限速，不保证降低 CPU。"
        } else {
            recommendation = advice.recommendation
        }

        let mainCandidates = identities.filter { identity in
            guard context.mainApplicationPIDs.contains(identity.pid) else { return false }
            guard let bundleID, let metadata = context.runningMetadata[identity.pid]?.bundleIdentifier else { return true }
            return metadata == bundleID
        }.sorted { $0.pid < $1.pid }
        let primaryIdentity = mainCandidates.first ?? representative.identity
        let mainPID = primaryIdentity.pid
        return AppProcess(
            id: primaryIdentity,
            memberIdentities: identities,
            pid: mainPID,
            parentPID: representative.parentPID,
            uid: representative.uid,
            name: representative.name,
            displayName: metadata.displayName,
            bundleIdentifier: bundleID,
            path: metadata.bundleRoot ?? AppResolver.appRoot(from: representative.path) ?? representative.path,
            cpuPercent: cpu,
            wakeupsPerSecond: wakeups,
            diskBytesPerSecond: disk,
            residentBytes: memory,
            isForeground: foreground,
            isBackground: !foreground,
            isSystem: isSystem,
            isProtected: protected,
            protectionReason: protectionReason,
            isSoftLimited: identities.contains(where: limited.contains),
            risk: risk,
            confidence: confidence,
            evidence: evidence,
            recommendation: recommendation,
            executablePath: members.first(where: { $0.identity == primaryIdentity })?.path,
            wakeupsAvailable: wakeupsAvailable,
            diskAvailable: diskAvailable,
            automaticContextBlockReason: automaticContextBlockReason
        )
    }

    private func confidenceFor(cpu: Double, averageCPU: Double, duration: TimeInterval, highFrames: Int,
                               wakeups: Double, thermal: ThermalLevel, protected: Bool) -> Double {
        var value = 0.10
        if cpu >= 35 { value += 0.15 }
        if averageCPU >= 35 { value += 0.15 }
        if duration >= 20 { value += 0.10 }
        if duration >= 60 { value += 0.25 }
        if highFrames >= 3 { value += 0.15 }
        if wakeups >= 100 { value += 0.10 }
        if thermal >= .fair { value += 0.05 }
        if protected { value = min(value, 0.55) }
        return min(max(value, 0), 0.99)
    }

    private static func groupKey(for delta: ProcessDelta, metadata: AppMetadata?) -> String {
        if let bundle = metadata?.bundleIdentifier { return "bundle:\(bundle)" }
        if let root = metadata?.bundleRoot ?? AppResolver.appRoot(from: delta.path) { return "app:\(root)" }
        return "process:\(delta.identity.pid):\(delta.identity.startAbstime)"
    }

    /// A terminal, IDE, or other foreground application can keep doing the
    /// user's work through a child process after the child itself has no
    /// window. Treating that child as a cold background target would make an
    /// automatic kill violate the user's project intent. The map is built from
    /// the same process frame, so this adds no extra sampler or shell work.
    private static func hasForegroundAncestor(identities: [ProcessIdentity],
                                               parentPIDs: [pid_t: pid_t],
                                               foregroundPID: pid_t?) -> Bool {
        guard let foregroundPID, foregroundPID > 1 else { return false }
        for identity in identities {
            var current = identity.pid
            var visited: Set<pid_t> = []
            while let parent = parentPIDs[current], parent > 1,
                  visited.insert(parent).inserted {
                if parent == foregroundPID { return true }
                current = parent
            }
        }
        return false
    }
}

enum ReportBuilder {
    static func make(
        duration: TimeInterval,
        thermal: ThermalLevel,
        hostCPU: Double,
        processes: [AppProcess],
        temperatureCelsius: Double? = nil,
        coverageNote: String = "常驻采样覆盖当前用户的可读取进程；系统进程可通过按需深扫补充。"
    ) -> DiagnosticReport {
        let candidates = Array(processes.filter {
            $0.cpuPercent >= 3 || $0.risk >= .elevated || $0.wakeupsPerSecond >= 500
        }.prefix(12))
        let suspicious = candidates.filter { $0.risk >= .elevated && !$0.isProtected }
        let protectedHot = candidates.filter { $0.isProtected && $0.cpuPercent >= 20 }
        let hardwareHot = temperatureCelsius.map { $0.isFinite && $0 >= 65 } ?? false
        let summary: String
        if !suspicious.isEmpty {
            summary = "发现 " + String(suspicious.count) + " 个有持续证据的后台负载。先核对是否是你正在等待的任务，再使用可撤销的优先级调整。"
        } else if hardwareHot {
            summary = "报告结束时的实验性硬件读数已达到 65°C；当前 CPU 进程没有形成可核验的持续高占用主因。请继续观察是否连续升温，并检查充电、外接显示器、GPU/视频任务和环境散热；温衡不会仅凭一次读数结束进程。"
        } else if thermal >= .serious {
            summary = protectedHot.isEmpty
                ? "系统热压力较高，但 CPU 进程没有充分解释它。还需考虑 GPU、视频编解码、充电、外接显示器或环境温度。"
                : "系统热压力较高；目前较热的来源包含受保护或预期任务，温衡不会自动干预它们。"
        } else if let first = candidates.first, first.cpuPercent >= 50 {
            summary = "主要 CPU 贡献者是 " + first.displayName + "，但当前证据不足以断言它在空转。"
        } else {
            summary = "本次没有发现明确的持续 CPU 异常。短时升温可能来自刚结束的任务，温衡会保留近期趋势供回看。"
        }

        return DiagnosticReport(
            date: Date(), duration: duration, thermal: thermal, hostCPUPercent: hostCPU,
            candidates: candidates, summary: summary, coverageNote: coverageNote
        )
    }
}
