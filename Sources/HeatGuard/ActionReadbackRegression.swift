import AppKit
import Foundation

/// Changes state while the production action is awaiting read-back. Commands
/// are recorded, never executed; every OS process here is our own sleep child.
@MainActor
enum ActionReadbackRegression {
    private final class Probe {
        var reads = 0
        var lowerCalls = 0
        var contextAllowed = true
        var protectedKeys: Set<String> = []
        weak var executor: ActionExecutor?
    }

    static func results(dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        var results: [(String, Bool)] = []
        for scenario in ["目标不变", "回读不可用", "已有非标准策略", "等待期间新增保护", "等待期间继承保护更新", "等待期间目标退出", "等待期间温衡退出"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            do { try child.run() } catch { results.append((scenario + "夹具启动", false)); continue }
            defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
            guard let raw = NativeSampler.process(pid: child.processIdentifier),
                  raw.parentPID == getpid(), raw.uid == getuid(), raw.path == "/bin/sleep" else {
                results.append((scenario + "夹具身份", false)); continue
            }
            let process = AppProcess(id: raw.identity, memberIdentities: [raw.identity],
                pid: raw.identity.pid, parentPID: raw.parentPID, uid: raw.uid, name: raw.name,
                displayName: "Read-back fixture", bundleIdentifier: nil, path: raw.path,
                cpuPercent: 100, wakeupsPerSecond: 0, diskBytesPerSecond: 0, residentBytes: 0,
                isForeground: false, isBackground: true, isSystem: false, isProtected: false,
                protectionReason: nil, isSoftLimited: false, risk: .high, confidence: 0.9,
                evidence: [], recommendation: "test only", executablePath: raw.path)
            let probe = Probe()
            let file = dataDirectory.appendingPathComponent(UUID().uuidString + ".json")
            let executor = ActionExecutor(journalURL: file, runner: { args in
                await MainActor.run {
                    if args.first == "-b" { probe.lowerCalls += 1 }
                    return CommandOutput(status: 0, output: Data(), error: "")
                }
            }, schedulingReader: { pid in
                await Task.yield()
                let first = await MainActor.run {
                    probe.reads += 1
                    if probe.reads == 1 {
                        if scenario == "等待期间新增保护" {
                            probe.protectedKeys = [process.protectionKey]
                        } else if scenario == "等待期间继承保护更新" {
                            probe.contextAllowed = false
                        } else if scenario == "等待期间目标退出", pid == child.processIdentifier {
                            child.terminate()
                            child.waitUntilExit()
                        }
                    }
                    return probe.reads == 1
                }
                if first, scenario == "等待期间温衡退出" {
                    await probe.executor?.prepareToQuit()
                }
                if scenario == "回读不可用" { return nil }
                let priority = scenario == "已有非标准策略" ? 4 : 31
                return SchedulingObservation(priority: priority, nice: 0, state: "S")
            }, protectedKeysReader: { probe.protectedKeys })
            probe.executor = executor
            let result = await executor.soften(process, confirmed: true, contextStillAllows: { probe.contextAllowed })
            let succeeded: Bool
            if case .success = result { succeeded = true } else { succeeded = false }
            // A missing pre-action scheduler read-back is now fail-closed:
            // applying `-b` could overwrite a policy that we cannot later
            // restore, so no native command or journal entry is allowed.
            let unchanged = scenario == "目标不变"
            let entries = (try? Data(contentsOf: file)).flatMap {
                try? JSONDecoder().decode([PolicyJournalEntry].self, from: $0)
            }
            results.append(("降级回读竞态：" + scenario,
                probe.reads > 0 && succeeded == unchanged
                && probe.lowerCalls == (unchanged ? 1 : 0)
                && executor.activeEntries.count == (unchanged ? 1 : 0)
                // A fail-closed pre-readback refusal need not create an empty
                // journal file at all; treat a missing file as zero entries.
                && (entries ?? []).count == (unchanged ? 1 : 0)))
            _ = await executor.restore(process)
        }
        return results
    }
}
