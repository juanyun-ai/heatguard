import Foundation

/// All processes here are synthetic. Exercise the real analyzer and policy
/// without creating CPU load, opening a window or sending any signal.
enum InheritedProtectionRegression {
    private static let owner: pid_t = 2_300_000
    private static let parent: pid_t = owner + 1
    private static let child: pid_t = owner + 2
    private static let ancestor: pid_t = owner + 3
    private static let bundle = "test.caldera"
    private static let root = "/Applications/Caldera.app"
    private static let parentPath = root + "/Contents/MacOS/Caldera"
    private static let childPath = "/private/tmp/caldera-worker"
    private static let ancestorPath = "/private/tmp/another-owner"
    private static let childIdentity = ProcessIdentity(pid: child, startAbstime: 124)
    private static let start = Date(timeIntervalSince1970: 2_000_000)

    static func results() -> [(name: String, passed: Bool)] {
        var results: [(String, Bool)] = []
        for key in [bundle, root, parentPath] {
            var analyzer = AnalysisEngine()
            let original = scan(&analyzer, at: 0, keys: [key])
            let detached = scan(&analyzer, at: 30, keys: [key], detached: true)
            let liveAfterGap = scan(&analyzer, at: 1_000, keys: [key], detached: true)
            results.append(("用户保护继承：上级退出后同一子任务仍受保护 " + key,
                original?.isProtected == true && detached?.isProtected == true
                    && detached?.protectionReason?.contains("Caldera") == true))
            results.append(("用户保护继承：同一存活身份跨长间隔不丢保护 " + key,
                liveAfterGap?.isProtected == true))
            analyzer.resetContinuousEvidence()
            let reset = scan(&analyzer, at: 1_015, keys: [key], detached: true)
            results.append(("用户保护继承：基线重建保留保护但 CPU 时长从零开始 " + key,
                reset?.isProtected == true && analyzer.history.values.allSatisfy { $0.highDuration == 0 }))
            let newIdentity = ProcessIdentity(pid: child, startAbstime: 125)
            let reused = scan(&analyzer, at: 1_030, keys: [key], detached: true, identity: newIdentity)
            let released = scan(&analyzer, at: 1_060, keys: [], detached: true)
            results.append(("用户保护继承：PID 复用不串保护，主动移除规则可解除 " + key,
                reused?.isProtected == false && released?.isProtected == false))
        }

        var multiple = AnalysisEngine()
        _ = scan(&multiple, at: 0, keys: [bundle, ancestorPath], hasAncestor: true)
        let remaining = scan(&multiple, at: 30, keys: [ancestorPath], detached: true)
        let none = scan(&multiple, at: 60, keys: [], detached: true)
        results.append(("用户保护继承：移除一个上级规则不覆盖另一个仍有效的保护",
            remaining?.isProtected == true && none?.isProtected == false))

        var expired = AnalysisEngine()
        _ = scan(&expired, at: 0, keys: [bundle])
        _ = expired.analyze(deltas: [], at: start.addingTimeInterval(601), thermal: .nominal,
            limited: [], ownPID: owner, rawProcesses: [])
        let afterAbsence = scan(&expired, at: 630, keys: [bundle], detached: true)
        results.append(("用户保护继承：长期缺失身份的关联会回收",
            afterAbsence?.isProtected == false))

        var analyzer = AnalysisEngine()
        var policy = AutomaticProtectionEngine()
        let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdleWithEphemeralCLI)
        var safe = true
        var last = AutoProtectionDecision(kind: .none, process: nil, reason: "")
        for seconds in stride(from: 0.0, through: 1_650.0, by: 30) {
            guard let row = scan(&analyzer, at: seconds, keys: [bundle], detached: seconds >= 90) else {
                safe = false; break
            }
            let now = start.addingTimeInterval(seconds)
            last = policy.observe(now: now, temperature: 85, temperatureDate: now,
                processes: [row], settings: settings, isScanning: false)
            safe = safe && row.isProtected && last.kind != .countdown && last.kind != .enforce
        }
        results.append(("真实分析到规则：85°C 高占用孤儿任务持续超过二十分钟仍遵守用户保护",
            safe && last.kind == .anomaly))
        return results
    }

    private static func scan(_ analyzer: inout AnalysisEngine, at seconds: TimeInterval,
        keys: Set<String>, detached: Bool = false, identity: ProcessIdentity = childIdentity,
        hasAncestor: Bool = false) -> AppProcess? {
        let parentPID: pid_t = detached ? 1 : parent
        let delta = ProcessDelta(identity: identity, parentPID: parentPID, uid: getuid(),
            name: "caldera-worker", path: childPath, cpuPercent: 120, wakeupsPerSecond: 0,
            diskBytesPerSecond: 0, residentBytes: 0, sampleDuration: 30,
            wakeupsAvailable: true, diskAvailable: true)
        func raw(_ id: ProcessIdentity, parentPID: pid_t, name: String, path: String) -> RawProcessSample {
            RawProcessSample(identity: id, parentPID: parentPID, uid: getuid(), name: name, path: path,
                cpuTimeNanoseconds: nil, interruptWakeups: nil, packageWakeups: nil,
                diskBytes: nil, residentBytes: nil)
        }
        var samples = [raw(identity, parentPID: parentPID, name: "caldera-worker", path: childPath)]
        var context = AnalysisContext(protectedBundleIDs: keys)
        if !detached {
            samples.append(raw(ProcessIdentity(pid: parent, startAbstime: 123),
                parentPID: hasAncestor ? ancestor : 1, name: "Caldera", path: parentPath))
            context.runningMetadata[parent] = AppMetadata(displayName: "Caldera",
                bundleIdentifier: bundle, bundleRoot: root)
            if hasAncestor {
                samples.append(raw(ProcessIdentity(pid: ancestor, startAbstime: 122),
                    parentPID: 1, name: "another-owner", path: ancestorPath))
            }
        }
        return analyzer.analyze(deltas: [delta], at: start.addingTimeInterval(seconds),
            thermal: .nominal, limited: [], ownPID: owner, context: context, rawProcesses: samples).first
    }
}
