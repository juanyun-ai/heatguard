import AppKit
import Foundation

/// Offline integration checks. Scheduling changes touch only private /bin/sleep
/// children created here. Journals and history are isolated in a temporary dir.
@MainActor
enum IntegrationTest {
    static func run() async -> Int32 {
        _ = NSApplication.shared
        let session = ProtectionSessionSnapshot.read()
        print("INFO: current session snapshot console=\(String(describing: session.onConsole)) login=\(String(describing: session.loginDone)) awake=\(String(describing: session.anyDisplayAwake)); this does not prove unlocked")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeatGuard-tests-\(UUID().uuidString)")
        var children: [Process] = []
        var failures: [String] = []
        var count = 0
        func check(_ name: String, _ result: Bool) {
            count += 1
            print("\(result ? "PASS" : "FAIL"): \(name)")
            if !result { failures.append(name) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                for child in children where child.isRunning {
                    child.terminate()
                    child.waitUntilExit()
                }
                // Only the unique test directory we just created.
                try? FileManager.default.removeItem(at: root)
            }
            for result in await TemperatureProviderTests.run() {
                check(result.name, result.passed)
            }
            for result in AutomaticControlRegression.results(dataDirectory: root.appendingPathComponent("automatic-control")) {
                check(result.name, result.passed)
            }
            for result in await ActionReadbackRegression.results(dataDirectory: root.appendingPathComponent("readback-race")) {
                check(result.name, result.passed)
            }
            for result in await ActionAncestryRegression.results(dataDirectory: root.appendingPathComponent("ancestry")) {
                check(result.name, result.passed)
            }
            for result in await InheritedProtectionIntegration.results(dataDirectory: root.appendingPathComponent("inherited")) {
                check(result.name, result.passed)
            }
            check("无效采样同时撤销排队动作令牌和倒计时状态",
                  MonitorModel.invalidFrameRevocationRegression(dataDirectory: root.appendingPathComponent("revocation")))
            for _ in 0..<2 {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sleep")
                child.arguments = ["120"]
                try child.run()
                children.append(child)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let raw = children.compactMap { NativeSampler.process(pid: $0.processIdentifier) }
            guard raw.count == 2 else { print("FAIL: native fixture identities unavailable"); return 1 }
            // The test host may itself inherit Darwin-background scheduling
            // from `swift run`/a terminal.  Normalize only these private
            // fixtures so the real action path exercises a standard baseline;
            // production targets that are already backgrounded are still
            // detected and refused by ActionExecutor.
            for sample in raw {
                _ = await CommandRunner.run("/usr/sbin/taskpolicy",
                    ["-B", "-p", String(sample.identity.pid)], timeout: 2)
            }
            let group = app(raw)
            check("动作前复核前台成员、用户保护与 PID 身份",
                !ActionSafety.canLower(raw[0], identity: raw[0].identity, app: group,
                    foregroundPID: raw[1].identity.pid, foregroundBundle: nil, protectedKeys: [])
                && !ActionSafety.canLower(raw[0], identity: raw[0].identity, app: group,
                    foregroundPID: nil, foregroundBundle: nil, protectedKeys: [group.protectionKey])
                && !ActionSafety.canLower(raw[0], identity: raw[1].identity, app: group,
                    foregroundPID: nil, foregroundBundle: nil, protectedKeys: []))

            // A real force-terminate fixture, isolated in this test's private
            // directory. It never targets a user application or a system PID.
            let forceFixture = Process()
            forceFixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
            forceFixture.arguments = ["120"]
            try forceFixture.run()
            children.append(forceFixture)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let forceRaw = NativeSampler.process(pid: forceFixture.processIdentifier) else {
                check("强制结束 fixture 身份可读", false)
                return 1
            }
            let forceApp = AppProcess(id: forceRaw.identity, memberIdentities: [forceRaw.identity],
                pid: forceRaw.identity.pid, parentPID: forceRaw.parentPID, uid: getuid(), name: forceRaw.name,
                displayName: "HeatGuard force fixture", bundleIdentifier: nil,
                path: AppResolver.appRoot(from: forceRaw.path) ?? forceRaw.path,
                cpuPercent: 100, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
                isForeground: false, isBackground: true, isSystem: false, isProtected: false,
                protectionReason: nil, isSoftLimited: false, risk: .high, confidence: 0.99,
                evidence: ["fixture"], recommendation: "test only", executablePath: forceRaw.path,
                wakeupsAvailable: true, diskAvailable: true)
            for result in await MonitorModel.manualConfirmationRegressions(process: forceApp,
                dataDirectory: root.appendingPathComponent("manual-confirmation")) {
                check(result.name, result.passed)
            }
            for result in await MonitorModel.permissionAndSessionRegressions(process: forceApp,
                dataDirectory: root.appendingPathComponent("permission-session")) {
                check(result.name, result.passed)
            }
            for result in await MonitorModel.globalStopRegressions(process: forceApp,
                dataDirectory: root.appendingPathComponent("global-stop")) {
                check(result.name, result.passed)
            }
            for result in MonitorModel.lifecycleCycleRegressions(process: forceApp,
                dataDirectory: root.appendingPathComponent("lifecycle-cycles")) {
                check(result.name, result.passed)
            }
            for result in await ActionExecutorFaultRegression.results(process: forceApp,
                dataDirectory: root.appendingPathComponent("action-faults")) {
                check(result.name, result.passed)
            }
            var autoEngine = AutomaticProtectionEngine()
            var autoSettings = AutoProtectionSettings(mode: .enforce)
            guard let forceGrant = AutomaticTerminationGrant(process: forceApp) else {
                check("自动规则夹具具有明确的完整身份授权", false)
                return 1
            }
            autoSettings.anomalyDuration = 60
            autoSettings.enforceDuration = 120
            let autoStart = Date(timeIntervalSince1970: 70_000)
            var autoDecision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 120.0, by: 60.0) {
                let point = autoStart.addingTimeInterval(offset)
                autoDecision = autoEngine.observe(now: point, temperature: 71, temperatureDate: point,
                                                  processes: [forceApp], settings: autoSettings, isScanning: false,
                                                  authorizedTargets: [forceGrant])
            }
            autoDecision = autoEngine.observe(now: autoStart.addingTimeInterval(151), temperature: 71,
                                              temperatureDate: autoStart.addingTimeInterval(151),
                                              processes: [forceApp], settings: autoSettings, isScanning: false,
                                              authorizedTargets: [forceGrant])
            check("自动规则经过 65/70°C 连续证据与倒计时后才发出 enforce", autoDecision.kind == .enforce)
            for result in await MonitorModel.automaticLifecycleRegressions(process: forceApp,
                dataDirectory: root.appendingPathComponent("granted-auto-execution"), scope: .explicitGrant) {
                check(result.name, result.passed)
            }

            // The more active scope is separately exercised against another
            // private sleep child. It must end only after the synthetic
            // low-I/O evidence window, without creating a per-target grant.
            let idleFixture = Process()
            idleFixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
            idleFixture.arguments = ["120"]
            try idleFixture.run()
            children.append(idleFixture)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let idleRaw = NativeSampler.process(pid: idleFixture.processIdentifier) else {
                check("空转自动处置 fixture 身份可读", false)
                return 1
            }
            let idleApp = AppProcess(id: idleRaw.identity, memberIdentities: [idleRaw.identity],
                pid: idleRaw.identity.pid, parentPID: idleRaw.parentPID, uid: getuid(), name: idleRaw.name,
                displayName: "HeatGuard idle fixture", bundleIdentifier: "com.leo.heatguard.test-idle",
                path: AppResolver.appRoot(from: idleRaw.path) ?? idleRaw.path,
                cpuPercent: 100, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
                isForeground: false, isBackground: true, isSystem: false, isProtected: false,
                protectionReason: nil, isSoftLimited: false, risk: .high, confidence: 0.99,
                evidence: ["fixture"], recommendation: "test only", executablePath: idleRaw.path,
                wakeupsAvailable: true, diskAvailable: true)
            for result in await MonitorModel.automaticLifecycleRegressions(process: idleApp,
                dataDirectory: root.appendingPathComponent("clear-idle-auto-execution"), scope: .clearIdle) {
                check(result.name, result.passed)
            }

            // The direct-timing path gets its own private child so the normal
            // cancellable lifecycle above remains an independent control.
            let immediateFixture = Process()
            immediateFixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
            immediateFixture.arguments = ["120"]
            try immediateFixture.run()
            children.append(immediateFixture)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let immediateRaw = NativeSampler.process(pid: immediateFixture.processIdentifier) else {
                check("直接自动结束 fixture 身份可读", false)
                return 1
            }
            let immediateApp = AppProcess(id: immediateRaw.identity, memberIdentities: [immediateRaw.identity],
                pid: immediateRaw.identity.pid, parentPID: immediateRaw.parentPID, uid: getuid(), name: immediateRaw.name,
                displayName: "HeatGuard immediate fixture", bundleIdentifier: "com.leo.heatguard.test-immediate",
                path: AppResolver.appRoot(from: immediateRaw.path) ?? immediateRaw.path,
                cpuPercent: 100, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
                isForeground: false, isBackground: true, isSystem: false, isProtected: false,
                protectionReason: nil, isSoftLimited: false, risk: .high, confidence: 0.99,
                evidence: ["fixture"], recommendation: "test only", executablePath: immediateRaw.path,
                wakeupsAvailable: true, diskAvailable: true)
            for result in await MonitorModel.automaticImmediateLowIORevalidationRegression(process: immediateApp,
                dataDirectory: root.appendingPathComponent("immediate-low-io-revalidation")) {
                check(result.name, result.passed)
            }
            for result in await MonitorModel.automaticImmediateExecutionRegression(process: immediateApp,
                dataDirectory: root.appendingPathComponent("immediate-auto-execution")) {
                check(result.name, result.passed)
            }

            let manualFixture = Process()
            manualFixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
            manualFixture.arguments = ["30"]
            try manualFixture.run()
            children.append(manualFixture)
            guard let manualRaw = NativeSampler.process(pid: manualFixture.processIdentifier) else {
                check("手动强制结束私有 fixture 身份可读", false)
                return 1
            }
            check("手动强制结束经过真实确认和排队后只结束私有目标",
                await MonitorModel.manualForceExecutionRegression(process: app([manualRaw]).withCPU(100),
                    dataDirectory: root.appendingPathComponent("manual-force-execution")))

            let journal = root.appendingPathComponent("partial.json")
            let probe = PolicyProbe(file: journal, failRestorePID: raw[1].identity.pid)
            let executor = ActionExecutor(journalURL: journal, runner: { await probe.run($0) })
            _ = await executor.soften(group)
            let unconfirmedCalls = await probe.calls
            check("没有确认不执行任何调度操作", unconfirmedCalls == 0 && executor.activeEntries.isEmpty)
            _ = await executor.soften(group, confirmed: true)
            let writeBeforeChange = await probe.allLowerIntentsPersisted
            check("先持久化恢复意图，再执行成员降级", executor.activeEntries.count == 2 && writeBeforeChange)
            _ = await executor.restore(group)
            let saved = try JSONDecoder().decode([PolicyJournalEntry].self, from: Data(contentsOf: journal))
            check("部分恢复失败不会遗忘尚未恢复的成员",
                  saved.map(\.identity) == [raw[1].identity] && executor.activeIdentities == [raw[1].identity])
            let beforeRetry = await probe.calls
            _ = await executor.maintain(foregroundPID: nil, foregroundBundle: nil)
            let afterRetry = await probe.calls
            check("恢复失败不会形成紧密重试循环", beforeRetry == afterRetry)
            await probe.allowRestore()
            _ = await executor.maintain(foregroundPID: nil, foregroundBundle: nil, now: Date().addingTimeInterval(65))
            check("退避后可继续恢复", executor.activeEntries.isEmpty)

            let delayed = DelayedPolicyProbe()
            let quitting = ActionExecutor(journalURL: root.appendingPathComponent("quit-race.json"),
                                           runner: { await delayed.run($0) })
            let inFlight = Task { await quitting.soften(app([raw[0]]), confirmed: true) }
            for _ in 0..<40 {
                if await delayed.entered { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            quitting.restoreAllSynchronously()
            check("退出同步兜底不删除尚在执行的降级意图", quitting.activeIdentities == [raw[0].identity])
            await quitting.prepareToQuit()
            _ = await inFlight.value
            check("正常退出等待在途降级结束后再恢复", quitting.activeEntries.isEmpty)

            let changedPath = RawProcessSample(identity: raw[0].identity, parentPID: raw[0].parentPID,
                uid: getuid(), name: "exec fixture", path: "/tmp/changed-executable",
                cpuTimeNanoseconds: 0, interruptWakeups: nil, packageWakeups: nil, diskBytes: nil, residentBytes: nil)
            let priorIntent = PolicyJournalEntry(identity: raw[0].identity, displayName: "fixture",
                createdAt: Date(), expiresAt: Date(), executablePath: raw[0].path)
            check("同一任务 exec 后仍允许撤销自己的旧调度",
                  ActionSafety.canRestore(changedPath, entry: priorIntent)
                  && !ActionSafety.canLower(changedPath, identity: raw[0].identity, app: app([raw[0]]),
                      foregroundPID: nil, foregroundBundle: nil, protectedKeys: []))

            let corrupt = root.appendingPathComponent("corrupt.json")
            let original = Data("unreadable journal fixture".utf8)
            try original.write(to: corrupt)
            let corruptExecutor = ActionExecutor(journalURL: corrupt)
            _ = await corruptExecutor.soften(group, confirmed: true)
            corruptExecutor.restoreAllSynchronously()
            check("损坏恢复文件关闭动作且退出时仍保留原件",
                  corruptExecutor.recoveryIssue != nil && (try? Data(contentsOf: corrupt)) == original)

            let blocked = root.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocked)
            let blockedProbe = PolicyProbe(file: blocked.appendingPathComponent("actions.json"))
            let blockedExecutor = ActionExecutor(journalURL: blocked.appendingPathComponent("actions.json"),
                                                  runner: { await blockedProbe.run($0) })
            _ = await blockedExecutor.soften(group, confirmed: true)
            let blockedCalls = await blockedProbe.calls
            check("无法保存恢复记录时禁止降级", blockedCalls == 0 && blockedExecutor.activeEntries.isEmpty)

            let realExecutor = ActionExecutor(journalURL: root.appendingPathComponent("real-policy.json"))
            let lower = await realExecutor.soften(app([raw[0]]), confirmed: true)
            let effectEvidence = realExecutor.activeEffectEvidence[raw[0].identity]
            if let effectEvidence {
                let before = effectEvidence.before.map { "\($0.priority)/\($0.nice)/\($0.state)" } ?? "unknown"
                let after = effectEvidence.after.map { "\($0.priority)/\($0.nice)/\($0.state)" } ?? "unknown"
                print("INFO: taskpolicy scheduler read-back " + before + " -> " + after)
                print("INFO: taskpolicy Darwin policy effect " + effectEvidence.summary)
                if let before = effectEvidence.before, let after = effectEvidence.after {
                    print("INFO: taskpolicy thread read-back before="
                        + String(describing: (before.darwinPolicy, before.darwinPriority,
                            before.darwinMaxPriority, before.darwinThreadCount,
                            before.darwinReadableThreads, before.darwinBackgroundThreads))
                        + " after="
                        + String(describing: (after.darwinPolicy, after.darwinPriority,
                            after.darwinMaxPriority, after.darwinThreadCount,
                            after.darwinReadableThreads, after.darwinBackgroundThreads)))
                }
            }
            let restore = await realExecutor.restore(app([raw[0]]))
            check("真实 taskpolicy 仅对测试子进程降级并恢复",
                  succeeded(lower) && succeeded(restore) && realExecutor.activeEntries.isEmpty
                  && effectEvidence?.before != nil && effectEvidence?.after != nil)
            // Always make a second best-effort restore of our fixture before termination.
            realExecutor.restoreAllSynchronously()

            let timeoutStart = ProcessInfo.processInfo.systemUptime
            let timeout = await CommandRunner.run("/bin/sleep", ["2"], timeout: 0.1)
            check("系统工具超时被限制且不阻塞 UI 线程",
                  timeout.status == -2 && ProcessInfo.processInfo.systemUptime - timeoutStart < 1.5)

            let invalidHistory = root.appendingPathComponent("history.json")
            try original.write(to: invalidHistory)
            let store = LocalStore(file: invalidHistory)
            _ = await store.load()
            try await store.save(SavedHistory())
            let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let backup = siblings.first { $0.lastPathComponent.hasPrefix("history.unreadable-") }
            check("损坏的历史保留备份后才写新记录",
                  backup != nil && (try? Data(contentsOf: backup!)) == original)

            // Keep this integration section deterministic even when the test
            // process runs headless, over SSH, or while the physical display
            // is asleep. Real-session gating is covered separately by the
            // injected-snapshot regressions above; this section verifies the
            // sampling/report and notification lifecycle itself.
            let interactiveSnapshot = ProtectionSessionSnapshot(
                onConsole: true, loginDone: true, anyDisplayAwake: true)
            var monitor: MonitorModel? = MonitorModel(
                dataDirectory: root.appendingPathComponent("monitor"),
                sessionSnapshot: { interactiveSnapshot }, preferences: InMemoryPreferences())
            for _ in 0..<30 where monitor?.lastSampleDate == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            check("模型启动完成本地采样", monitor?.lastSampleDate != nil && (monitor?.totalProcessCount ?? 0) > 0)
            monitor?.beginDiagnostic(duration: 10)
            for _ in 0..<110 where monitor?.isScanning == true { try await Task.sleep(nanoseconds: 200_000_000) }
            check("短程排查完成报告并保持采集覆盖信息",
                  monitor?.isScanning == false && monitor?.report != nil
                  && monitor?.report?.coverageNote.contains("CPU 可读") == true)

            let oldDate = monitor?.lastSampleDate
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            monitor?.sampleNowFromUI()
            try await Task.sleep(nanoseconds: 150_000_000)
            let noSleepSampling = monitor?.lastSampleDate == oldDate
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            check("正确工作区通知中心的模拟睡眠暂停与唤醒重建",
                  noSleepSampling && monitor?.lastSampleDate != oldDate)
            // These notifications are local to this test process; they do not
            // sleep/lock the Mac or send distributed session notifications.
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            let beforeOverlap = monitor?.lastSampleDate
            workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            monitor?.sampleNowFromUI()
            monitor?.beginDiagnostic(duration: 10)
            try await Task.sleep(nanoseconds: 150_000_000)
            check("屏幕唤醒不能解除仍失活的会话或开始排查",
                  monitor?.lastSampleDate == beforeOverlap && monitor?.isScanning == false)
            workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            for _ in 0..<20 where monitor?.lastSampleDate == beforeOverlap {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            check("全部会话条件恢复后模型重新采样", monitor?.lastSampleDate != beforeOverlap)
            await monitor?.prepareForTermination()
            monitor = nil
        } catch {
            check("集成测试执行", false)
            print(error.localizedDescription)
        }
        print("HeatGuard integration-test: \(count - failures.count)/\(count) passed")
        return failures.isEmpty ? 0 : 1
    }

    private static func succeeded(_ result: ActionResult) -> Bool {
        if case .success = result { return true }
        return false
    }
    private static func app(_ members: [RawProcessSample]) -> AppProcess {
        let first = members[0]
        return AppProcess(id: first.identity, memberIdentities: members.map(\.identity),
            pid: first.identity.pid, parentPID: getpid(), uid: getuid(), name: "sleep",
            displayName: "HeatGuard test fixture", bundleIdentifier: nil, path: first.path,
            cpuPercent: 0, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
            isForeground: false, isBackground: true, isSystem: false, isProtected: false,
            protectionReason: nil, isSoftLimited: false, risk: .watch, confidence: 0,
            evidence: [], recommendation: "test only", executablePath: first.path)
    }
}

private actor PolicyProbe {
    let file: URL
    var failRestorePID: pid_t?
    private(set) var calls = 0
    private(set) var allLowerIntentsPersisted = true
    init(file: URL, failRestorePID: pid_t? = nil) {
        self.file = file
        self.failRestorePID = failRestorePID
    }
    func allowRestore() { failRestorePID = nil }
    func run(_ arguments: [String]) -> CommandOutput {
        calls += 1
        let pid = arguments.last.flatMap(Int32.init)
        if arguments.first == "-b" {
            let entries = (try? JSONDecoder().decode([PolicyJournalEntry].self, from: Data(contentsOf: file))) ?? []
            allLowerIntentsPersisted = allLowerIntentsPersisted && entries.contains { $0.identity.pid == pid }
        }
        let failure = arguments.first == "-B" && pid == failRestorePID
        return CommandOutput(status: failure ? 1 : 0, output: Data(), error: failure ? "fixture failure" : "")
    }
}

private actor DelayedPolicyProbe {
    private(set) var entered = false
    func run(_ arguments: [String]) async -> CommandOutput {
        if arguments.first == "-b" {
            entered = true
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return CommandOutput(status: 0, output: Data(), error: "")
    }
}
