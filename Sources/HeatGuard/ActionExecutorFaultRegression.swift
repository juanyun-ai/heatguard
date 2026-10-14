import AppKit
import Darwin
import Foundation

/// Negative integration checks through the real manual-action entry points.
/// The caller must supply its own direct /bin/sleep child. Every snapshot keeps
/// that child's dispatch PID unchanged, even when its identity evidence is bad.
/// These checks expect pre-dispatch refusals; they do not test GUI interaction,
/// NSRunningApplication's successful termination path, or automatic protection.
/// A CLI sleep task may lack NSRunningApplication support. The normal-quit
/// refusal alone therefore cannot prove which guard rejected it; its results
/// are non-dispatch observations, not independent condition-level coverage.
/// Condition coverage also relies on the positive-controlled shared gate and
/// the force-termination path, whose valid fixture is later really terminated.
@MainActor
enum ActionExecutorFaultRegression {
    static func results(process: AppProcess, dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        let originalIdentity = process.id
        let originalPID = process.pid
        let originalRaw = NativeSampler.process(pid: originalPID)
        let foreground = NSWorkspace.shared.frontmostApplication
        let protectedKeys = Set(UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? [])
        let privateFixtureIsValid = originalPID > 1 && originalPID != getpid()
            && originalIdentity.pid == originalPID
            && originalRaw?.identity == originalIdentity
            && originalRaw?.parentPID == getpid()
            && originalRaw?.uid == getuid()
            && originalRaw?.path == "/bin/sleep"
            && process.memberIdentities == [originalIdentity]
            && process.executablePath == "/bin/sleep"
            && !process.isSystem && !process.isProtected && !process.isForeground
        let positiveGate = originalRaw.map {
            ActionSafety.canLower($0, identity: originalIdentity, app: process,
                foregroundPID: foreground?.processIdentifier,
                foregroundBundle: foreground?.bundleIdentifier, protectedKeys: protectedKeys)
        } ?? false
        var results: [(name: String, passed: Bool)] = [
            ("动作入口前置：自身私有 sleep 身份及共用门禁阳性", privateFixtureIsValid && positiveGate)
        ]
        // Never operate on an arbitrary process accidentally supplied by a
        // caller. In particular, a failed positive control is not 24 passes.
        guard privateFixtureIsValid, positiveGate else { return results }

        let foreignUID: uid_t = getuid() == 0 ? 1 : 0
        let staleStart = originalIdentity.startAbstime > 1 ? originalIdentity.startAbstime - 1 : 2
        let snapshots: [(name: String, process: AppProcess)] = [
            ("系统标志", copy(process, isSystem: true)),
            ("受保护标志", copy(process, isProtected: true)),
            ("前台标志", copy(process, isForeground: true)),
            ("陈旧启动时间", copy(process, identity: ProcessIdentity(pid: originalPID, startAbstime: staleStart))),
            ("缺失启动时间", copy(process, identity: ProcessIdentity(pid: originalPID, startAbstime: 0))),
            ("身份 PID 与固定目标 PID 不同", copy(process, identity: ProcessIdentity(pid: 0, startAbstime: originalIdentity.startAbstime))),
            ("快照属于其他用户", copy(process, uid: foreignUID)),
            ("应用路径不匹配", copy(process, path: process.path + ".unexpected")),
            ("应用路径为空", copy(process, path: "")),
            ("精确可执行路径不匹配", copy(process, executablePath: "/bin/sleep.unexpected")),
            ("精确可执行路径为空", copy(process, executablePath: "")),
            ("会议知识库保护", copy(process, bundleIdentifier: "us.zoom.xos"))
        ]
        // Only initialization is needed: rejected termination requests do not
        // write a journal. A unique path cannot load the user's action history.
        let executor = ActionExecutor(journalURL: dataDirectory.appendingPathComponent(
            "entrypoint-refusals-\(UUID().uuidString).json"))
        let requestRefusal = "目标已变化、受保护，或不支持正常退出请求。"
        let forceRefusal = "目标已变化、受保护，或无法安全核验；没有强制结束。"

        func fixtureIsUnchanged() -> Bool {
            guard let raw = NativeSampler.process(pid: originalPID) else { return false }
            return raw.identity == originalIdentity && raw.parentPID == getpid()
                && raw.uid == getuid() && raw.path == "/bin/sleep"
        }

        for fault in snapshots {
            // Keep dispatch permanently bound to the test child; changing id
            // is allowed only as malformed evidence, not as a new destination.
            guard fault.process.pid == originalPID, fixtureIsUnchanged() else {
                results.append(("动作入口中止：\(fault.name) 前私有 fixture 不再一致", false))
                return results
            }
            let requested = executor.requestTerminate(fault.process)
            let requestPreservedFixture = fixtureIsUnchanged()
            results.append(("正常退出入口拒绝：" + fault.name,
                isFailure(requested, exactly: requestRefusal) && requestPreservedFixture))
            guard requestPreservedFixture else { return results }

            let forced = await executor.forceTerminate(fault.process)
            let forcePreservedFixture = fixtureIsUnchanged()
            results.append(("强制结束入口拒绝：" + fault.name,
                isFailure(forced, exactly: forceRefusal) && forcePreservedFixture))
            guard forcePreservedFixture else { return results }
        }
        results.append(("动作入口拒绝矩阵完成后私有 fixture 仍为原身份且没有调度记录",
                        fixtureIsUnchanged() && executor.activeEntries.isEmpty))
        return results
    }

    private static func isFailure(_ result: ActionResult, exactly message: String) -> Bool {
        guard case .failure(let actual) = result else { return false }
        return actual == message
    }

    /// Deliberately has no PID parameter. A fault can invalidate evidence, but
    /// it cannot redirect either action entry point to any other process.
    private static func copy(_ process: AppProcess, identity: ProcessIdentity? = nil,
                             uid: uid_t? = nil, path: String? = nil, executablePath: String? = nil,
                             bundleIdentifier: String? = nil, isSystem: Bool? = nil,
                             isProtected: Bool? = nil, isForeground: Bool? = nil) -> AppProcess {
        AppProcess(id: identity ?? process.id, memberIdentities: process.memberIdentities,
            pid: process.pid, parentPID: process.parentPID, uid: uid ?? process.uid,
            name: process.name, displayName: process.displayName,
            bundleIdentifier: bundleIdentifier ?? process.bundleIdentifier, path: path ?? process.path,
            cpuPercent: process.cpuPercent, wakeupsPerSecond: process.wakeupsPerSecond,
            diskBytesPerSecond: process.diskBytesPerSecond, residentBytes: process.residentBytes,
            isForeground: isForeground ?? process.isForeground, isBackground: process.isBackground,
            isSystem: isSystem ?? process.isSystem, isProtected: isProtected ?? process.isProtected,
            protectionReason: process.protectionReason, isSoftLimited: process.isSoftLimited,
            risk: process.risk, confidence: process.confidence, evidence: process.evidence,
            recommendation: process.recommendation, executablePath: executablePath ?? process.executablePath)
    }
}
