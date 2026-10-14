import Darwin
import Foundation

/// Native parent exit/reparenting, using only an owned shell and its sleep
/// child. CPU/time inputs are synthetic; lineage and dispatch are real.
@MainActor
enum InheritedProtectionIntegration {
    static func results(dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        let parent = Process()
        // On this Mac /bin/sh is a launcher whose observed image becomes
        // /bin/bash. Launch the actual system executable to bind the fixture
        // to one known native path instead of assuming the wrapper persists.
        parent.executableURL = URL(fileURLWithPath: "/bin/bash")
        // End the parent by closing its private control input. Sending a
        // termination request is not a valid orphan fixture if the runtime
        // also tears down the child's process group.
        parent.arguments = ["-c", "/bin/sleep 30 & IFS= read -r heatguard_fixture_exit; exit 0"]
        parent.environment = ["PATH": "/usr/bin:/bin", "BASH_ENV": "/dev/null"]
        let controlInput = Pipe()
        parent.standardInput = controlInput
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        do { try parent.run() }
        catch { return [("孤儿保护原生夹具启动", false)] }
        var child: RawProcessSample?
        defer {
            // Parent may already be gone. Cleanup is bound to the child we
            // discovered while it was provably ours, not its current parent.
            if let child, let live = NativeSampler.process(pid: child.identity.pid),
               live.identity == child.identity, live.path == "/bin/sleep", live.uid == getuid() {
                Darwin.kill(live.identity.pid, SIGTERM)
            }
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }
        for _ in 0..<40 {
            child = NativeSampler.processes().first {
                $0.parentPID == parent.processIdentifier && $0.uid == getuid() && $0.path == "/bin/sleep"
            }
            if child != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let observedParent = NativeSampler.process(pid: parent.processIdentifier)
        print("INFO: inherited fixture child_found=\(child != nil) parent_found=\(observedParent != nil) parent_is_ours=\(observedParent?.parentPID == getpid()) parent_path=\(observedParent?.path ?? "unavailable")")
        guard let owned = child, let upstream = observedParent,
              upstream.parentPID == getpid(), upstream.uid == getuid(), upstream.path == "/bin/bash" else {
            return [("孤儿保护原生夹具父子身份", false)]
        }
        var analyzer = AnalysisEngine()
        let initial = Date()
        var keys: Set<String> = [upstream.path]
        func analyze(_ raw: RawProcessSample, time: Date, parents: [RawProcessSample]) -> AppProcess? {
            let delta = ProcessDelta(identity: raw.identity, parentPID: raw.parentPID, uid: raw.uid,
                name: raw.name, path: raw.path, cpuPercent: 120, wakeupsPerSecond: 0,
                diskBytesPerSecond: 0, residentBytes: 0, sampleDuration: 30,
                wakeupsAvailable: true, diskAvailable: true)
            return analyzer.analyze(deltas: [delta], at: time, thermal: .nominal, limited: [],
                ownPID: getpid(), context: AnalysisContext(protectedBundleIDs: keys),
                rawProcesses: [raw] + parents).first
        }
        let attached = analyze(owned, time: initial, parents: [upstream])
        var results = [("原生继承保护：只保护测试父进程即可保护子任务", attached?.isProtected == true)]
        guard attached?.isProtected == true else { return results }
        try? controlInput.fileHandleForWriting.close()
        for _ in 0..<80 where parent.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        guard !parent.isRunning else { return results + [("测试父进程正常结束", false)] }
        parent.waitUntilExit()
        let observedOrphan = NativeSampler.process(pid: owned.identity.pid)
        print("INFO: inherited fixture after parent exit child_found=\(observedOrphan != nil) same_identity=\(observedOrphan?.identity == owned.identity) parent_pid=\(observedOrphan?.parentPID ?? -1)")
        guard let orphan = observedOrphan,
              orphan.identity == owned.identity, orphan.path == owned.path, orphan.parentPID == 1,
              let detached = analyze(orphan, time: initial.addingTimeInterval(30), parents: []) else {
            return results + [("测试子任务由 launchd 接管且身份不变", false)]
        }
        let executor = ActionExecutor(journalURL: dataDirectory.appendingPathComponent("actions.json"),
            protectedKeysReader: { keys })
        let attempted = await executor.forceTerminate(detached, automatic: true)
        let refused: Bool
        if case .failure = attempted { refused = true } else { refused = false }
        let stillAlive = NativeSampler.process(pid: owned.identity.pid)?.identity == owned.identity
        results.append(("原生继承保护：父进程真实退出后自动强杀仍被拒绝，子任务存活",
            detached.isProtected && refused && stillAlive))
        guard refused && stillAlive else { return results }
        keys = []
        guard let released = analyze(orphan, time: initial.addingTimeInterval(60), parents: []),
              !released.isProtected else { return results + [("移除测试上级保护后可解除", false)] }
        // Removing an explicit rule need not make a known shell's computation
        // automatically disposable. This positive control is a manual action.
        let result = await executor.forceTerminate(released)
        let ended: Bool
        if case .success = result { ended = true } else { ended = false }
        for _ in 0..<40 where NativeSampler.process(pid: owned.identity.pid) != nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        results.append(("原生继承保护阳性：移除规则后手动结束私有目标并核验消失",
            ended && NativeSampler.process(pid: owned.identity.pid) == nil))
        return results
    }
}
