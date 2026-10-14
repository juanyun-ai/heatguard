import AppKit
import Darwin
import Foundation

/// Real /bin/sh -> /bin/sleep ancestry owned by this test. Uses in-memory
/// protection settings, never UserDefaults or a copied executable/App bundle.
@MainActor
enum ActionAncestryRegression {
    static func results(dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "/bin/sleep 20 & wait"]
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        var ownedChild: RawProcessSample?
        do { try parent.run() }
        catch { return [("上级保护动作夹具启动", false)] }
        defer {
            if let child = ownedChild,
               let live = NativeSampler.process(pid: child.identity.pid),
               live.identity == child.identity, live.path == "/bin/sleep",
               live.parentPID == parent.processIdentifier {
                Darwin.kill(child.identity.pid, SIGTERM)
            }
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }
        for _ in 0..<40 {
            ownedChild = NativeSampler.processes().first {
                $0.parentPID == parent.processIdentifier && $0.uid == getuid() && $0.path == "/bin/sleep"
            }
            if ownedChild != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let child = ownedChild,
              let parentRaw = NativeSampler.process(pid: parent.processIdentifier),
              parentRaw.parentPID == getpid(), parentRaw.uid == getuid(),
              child.identity.startAbstime > 0 else { return [("上级保护夹具具有真实两级父链", false)] }
        let app = AppProcess(id: child.identity, memberIdentities: [child.identity],
            pid: child.identity.pid, parentPID: child.parentPID, uid: child.uid, name: child.name,
            displayName: "HeatGuard ancestry fixture", bundleIdentifier: nil, path: child.path,
            cpuPercent: 120, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
            isForeground: false, isBackground: true, isSystem: false, isProtected: false,
            protectionReason: nil, isSoftLimited: false, risk: .high, confidence: 1,
            evidence: [], recommendation: "test only", executablePath: child.path,
            wakeupsAvailable: true, diskAvailable: true)
        var keys: Set<String> = []
        let executor = ActionExecutor(journalURL: dataDirectory.appendingPathComponent("actions.json"),
            protectedKeysReader: { keys })
        let foreground = NSWorkspace.shared.frontmostApplication
        let positive = ActionSafety.canLower(child, identity: child.identity, app: app,
            foregroundPID: foreground?.processIdentifier, foregroundBundle: foreground?.bundleIdentifier,
            protectedKeys: [], automatic: true)
        var results = [("真实父链阳性对照：独立私有子任务可通过最终自动门禁", positive)]
        guard positive else { return results }
        // The child snapshot predates this protection edit. Only the final
        // native ancestry read and current protection keys can refuse it.
        keys = [parentRaw.path]
        let result = await executor.forceTerminate(app, automatic: true)
        let refused: Bool
        if case .failure = result { refused = true } else { refused = false }
        let alive = NativeSampler.process(pid: child.identity.pid)?.identity == child.identity
        results.append(("真实动作：采样后保护上级也拒绝强杀且子任务仍存活", refused && alive))
        guard refused && alive else { return results }
        keys = []
        let ended = await executor.forceTerminate(app, automatic: true)
        let succeeded: Bool
        if case .success = ended { succeeded = true } else { succeeded = false }
        for _ in 0..<40 where parent.isRunning {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        results.append(("真实动作阳性对照：解除上级保护后仅结束私有目标并由父进程回收",
            succeeded && !parent.isRunning && NativeSampler.process(pid: child.identity.pid) == nil))
        return results
    }
}
