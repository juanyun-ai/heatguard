import Foundation

/// Deterministic real analysis/policy tests. No signals, settings or CPU load.
enum ProcessAncestryRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let owner: pid_t = 2_200_000
        let parent: pid_t = owner + 1
        let child: pid_t = owner + 2
        let start = Date(timeIntervalSince1970: 980_000)
        let parentPath = "/Applications/Caldera.app/Contents/MacOS/Caldera"
        func node(_ pid: pid_t, parentPID: pid_t = 1, name: String = "Caldera",
                  path: String = "/Applications/Caldera.app/Contents/MacOS/Caldera",
                  bundle: String? = "test.caldera") -> ProcessAncestryGate.Node {
            ProcessAncestryGate.Node(identity: ProcessIdentity(pid: pid, startAbstime: 123),
                parentPID: parentPID, uid: getuid(), name: name, path: path, bundleIdentifier: bundle,
                protectedTask: LocalKnowledgeBase.advice(name: name, path: path, bundleIdentifier: bundle).protected,
                excludedFromAutomatic: LocalKnowledgeBase.isAutomaticProtectionExcluded(name: name,
                    path: path, bundleIdentifier: bundle))
        }
        func verdict(_ nodes: [pid_t: ProcessAncestryGate.Node], keys: Set<String> = []) -> ProcessAncestryGate.Verdict {
            ProcessAncestryGate.evaluate(parentPID: parent, ownPID: owner,
                protectedKeys: keys, lookup: { nodes[$0] })
        }
        let clean = [parent: node(parent)]
        var results: [(String, Bool)] = []
        results.append(("祖先门禁：完整无保护父链是阳性对照", verdict(clean) == .clear))
        for key in ["test.caldera", "/Applications/Caldera.app", parentPath] {
            results.append(("祖先门禁：继承上级保护键 " + key,
                verdict(clean, keys: [key]).manualBlockReason != nil))
        }
        let important = verdict([parent: node(parent, name: "Terminal",
            path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", bundle: "com.apple.Terminal")])
        results.append(("祖先门禁：工程或终端子任务自动只提醒但仍可手动审查",
            important.automaticBlockReason != nil && important.manualBlockReason == nil))
        let mixed = [parent: node(parent, parentPID: parent + 10, name: "node", path: "/opt/homebrew/bin/node", bundle: nil),
            parent + 10: node(parent + 10)]
        results.append(("祖先门禁：重要任务之上的明确保护优先于手动许可",
            verdict(mixed, keys: ["test.caldera"]).manualBlockReason != nil))
        let malformed: [[pid_t: ProcessAncestryGate.Node]] = [[:],
            [parent: node(parent, parentPID: parent)],
            [parent: node(parent, parentPID: 0)],
            [parent: node(parent + 1)],
            [parent: node(parent, path: "")],
            [parent: ProcessAncestryGate.Node(identity: ProcessIdentity(pid: parent, startAbstime: 0),
                parentPID: 1, uid: getuid(), name: "unknown", path: "/tmp/unknown")]]
        results.append(("祖先门禁：缺失循环无效 PID 路径或启动身份均不放行",
            malformed.allSatisfy { verdict($0) == .unknown }))
        var calls = 0
        let bounded = ProcessAncestryGate.evaluate(parentPID: parent, ownPID: owner, protectedKeys: []) { pid in
            calls += 1
            return node(pid, parentPID: pid + 1)
        }
        results.append(("祖先门禁：无终点父链最多查询 64 个节点", bounded == .unknown && calls == 64))

        func raw(_ n: ProcessAncestryGate.Node) -> RawProcessSample {
            RawProcessSample(identity: n.identity, parentPID: n.parentPID, uid: n.uid,
                name: n.name, path: n.path, cpuTimeNanoseconds: nil,
                interruptWakeups: nil, packageWakeups: nil, diskBytes: nil, residentBytes: nil)
        }
        let childIdentity = ProcessIdentity(pid: child, startAbstime: 124)
        let delta = ProcessDelta(identity: childIdentity, parentPID: parent, uid: getuid(), name: "unlabelled-worker",
            path: "/private/tmp/unlabelled-worker", cpuPercent: 120, wakeupsPerSecond: 0,
            diskBytesPerSecond: 0, residentBytes: 0, sampleDuration: 30, wakeupsAvailable: true, diskAvailable: true)
        let childNode = ProcessAncestryGate.Node(identity: childIdentity, parentPID: parent,
            uid: getuid(), name: delta.name, path: delta.path)
        let metadata = AppMetadata(displayName: "Caldera", bundleIdentifier: "test.caldera", bundleRoot: "/Applications/Caldera.app")
        var analyzer = AnalysisEngine()
        var context = AnalysisContext(protectedBundleIDs: ["test.caldera"])
        context.runningMetadata = [parent: metadata]
        let childRow = analyzer.analyze(deltas: [delta], at: start, thermal: .nominal,
            limited: [], ownPID: owner, context: context, rawProcesses: [raw(clean[parent]!), raw(childNode)]).first
        context.protectedBundleIDs = []
        let released = analyzer.analyze(deltas: [delta], at: start.addingTimeInterval(30), thermal: .nominal,
            limited: [], ownPID: owner, context: context, rawProcesses: [raw(clean[parent]!), raw(childNode)]).first
        results.append(("真实分析：无 CPU 计数的上级仍传递保护且下一帧解除不命中旧缓存",
            childRow?.isProtected == true && childRow?.protectionReason?.contains("上级任务") == true
                && released?.isProtected == false && released?.automaticContextBlockReason == nil))
        var foregroundContext = context
        foregroundContext.foregroundPID = parent + 10
        let activeRoot = node(parent + 10)
        let unreadableBridge = node(parent, parentPID: parent + 10, name: "bridge", path: "/tmp/bridge", bundle: nil)
        let foregroundChild = analyzer.analyze(deltas: [delta], at: start.addingTimeInterval(60),
            thermal: .nominal, limited: [], ownPID: owner, context: foregroundContext,
            rawProcesses: [raw(activeRoot), raw(unreadableBridge), raw(childNode)]).first
        results.append(("真实分析：中间祖先缺少 CPU 数据也不丢失前台子任务保护",
            foregroundChild?.isForeground == true && foregroundChild?.isProtected == true))

        var detachedAnalyzer = AnalysisEngine()
        let terminal = node(parent, name: "Terminal",
            path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            bundle: "com.apple.Terminal")
        let attached = detachedAnalyzer.analyze(deltas: [delta], at: start,
            thermal: .nominal, limited: [], ownPID: owner,
            rawProcesses: [raw(terminal), raw(childNode)]).first
        let detachedChild = RawProcessSample(identity: childIdentity, parentPID: 1, uid: getuid(),
            name: childNode.name, path: childNode.path, cpuTimeNanoseconds: nil,
            interruptWakeups: nil, packageWakeups: nil, diskBytes: nil, residentBytes: nil)
        let detached = detachedAnalyzer.analyze(deltas: [delta], at: start.addingTimeInterval(30),
            thermal: .nominal, limited: [], ownPID: owner,
            rawProcesses: [detachedChild]).first
        results.append(("脱离父链后仍保留同一 PID/启动身份的重要任务保护",
            attached?.automaticContextBlockReason != nil
                && detached?.isProtected == false
                && detached?.automaticContextBlockReason?.contains("Terminal") == true))

        for protected in [false, true] {
            var engine = AutomaticProtectionEngine()
            var analyzer = AnalysisEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdleWithEphemeralCLI)
            var firstCountdown: Double?
            var last = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            let upstream = protected ? node(parent, name: "node", path: "/opt/homebrew/bin/node", bundle: nil) : node(parent)
            for seconds in stride(from: 0.0, through: 1_290.0, by: 30.0) {
                let now = start.addingTimeInterval(seconds)
                guard let row = analyzer.analyze(deltas: [delta], at: now, thermal: .nominal,
                    limited: [], ownPID: owner, rawProcesses: [raw(upstream), raw(childNode)]).first else {
                    results.append(("真实分析到自动规则：夹具行存在", false)); return results
                }
                last = engine.observe(now: now, temperature: 85, temperatureDate: now,
                    processes: [row], settings: settings, isScanning: false)
                if last.kind == .countdown && firstCountdown == nil { firstCountdown = seconds }
            }
            results.append((protected ? "真实分析到规则：匿名临时 worker 继承工程排除且仍高温提醒"
                : "真实分析到规则：独立低 I/O 临时 worker 完整二十分钟后仍能执行",
                protected ? firstCountdown == nil && last.kind == .anomaly
                    && last.reason.contains("工程") : firstCountdown == 1_260 && last.kind == .enforce))
        }

        if let row = released {
            let childRaw = raw(childNode)
            func actionAllowed(automatic: Bool, keys: Set<String> = []) -> Bool {
                ActionSafety.canLower(childRaw, identity: childNode.identity, app: row,
                    foregroundPID: nil, foregroundBundle: nil, protectedKeys: keys,
                    automatic: automatic, ancestryLookup: { pid in
                        pid == parent ? node(parent, name: "node", path: "/opt/homebrew/bin/node", bundle: nil) : nil
                    })
            }
            results.append(("最终共用门禁：新的工程父链阻挡自动而不冒充手动权限",
                actionAllowed(automatic: false) && !actionAllowed(automatic: true)
                    && !actionAllowed(automatic: false, keys: ["/opt/homebrew/bin/node"])))
            var tagged = row
            tagged.automaticContextBlockReason = "来自工程任务，只提醒。"
            let encoded = try? JSONEncoder().encode(tagged)
            let restored = encoded.flatMap { try? JSONDecoder().decode(AppProcess.self, from: $0) }
            results.append(("历史报告和 CPU 均值副本保留工程归属解释",
                restored?.automaticContextBlockReason == tagged.automaticContextBlockReason
                    && tagged.withCPU(90).automaticContextBlockReason == tagged.automaticContextBlockReason))
        }
        return results
    }
}
