import AppKit
import Darwin
import Foundation

struct PolicyJournalEntry: Codable, Sendable, Hashable, Identifiable {
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let displayName: String
    let createdAt: Date
    let expiresAt: Date
    var executablePath: String? = nil
    var bundleIdentifier: String? = nil
}

/// The journal is the sole source of active operations. Persist the intent
/// before changing policy, retain failed restores, and serialize mutations.
@MainActor
final class ActionExecutor {
    typealias Runner = @Sendable ([String]) async -> CommandOutput
    typealias SchedulingReader = @Sendable (pid_t) async -> SchedulingObservation?
    private var journal: [PolicyJournalEntry] = []
    private let journalURL: URL
    private let runner: Runner
    private let schedulingReader: SchedulingReader
    private let protectedKeysReader: () -> Set<String>
    private var retryAfter: [ProcessIdentity: Date] = [:]
    private var busy = false
    private var shuttingDown = false
    private var quitRecoveryAttempted = false
    private var applying: Set<ProcessIdentity> = []
    private var loadError: String?
    private var effectEvidence: [ProcessIdentity: PolicyEffectEvidence] = [:]

    init(journalURL: URL? = nil, runner: @escaping Runner = {
        await CommandRunner.run("/usr/sbin/taskpolicy", $0, timeout: 3)
    }, schedulingReader: @escaping SchedulingReader = {
        await CommandRunner.schedulingObservation(pid: $0)
    }, protectedKeysReader: @escaping () -> Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? [])
    }) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.journalURL = journalURL ?? base.appendingPathComponent("HeatGuard/actions-v1.json")
        self.runner = runner
        self.schedulingReader = schedulingReader
        self.protectedKeysReader = protectedKeysReader
        if FileManager.default.fileExists(atPath: self.journalURL.path) {
            do {
                let size = try self.journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 131_072 else { throw CocoaError(.fileReadTooLarge) }
                let entries = try JSONDecoder().decode([PolicyJournalEntry].self, from: Data(contentsOf: self.journalURL))
                var seen: Set<ProcessIdentity> = []
                journal = entries.filter { seen.insert($0.identity).inserted }
                guard journal.count <= 256 else { throw CocoaError(.fileReadTooLarge) }
            } catch {
                loadError = "恢复记录无法读取；已暂时禁用调度操作，原文件保持不变。"
                journal = []
            }
        }
    }

    var activeEntries: [PolicyJournalEntry] { journal }
    var activeIdentities: Set<ProcessIdentity> { Set(journal.map(\.identity)) }
    var recoveryIssue: String? { loadError }
    var activeEffectEvidence: [ProcessIdentity: PolicyEffectEvidence] { effectEvidence }

    func soften(_ process: AppProcess, confirmed: Bool = false,
                contextStillAllows: () -> Bool = { true }) async -> ActionResult {
        guard confirmed else { return .failure("请先确认后台调度的影响。") }
        if let loadError { return .failure(loadError) }
        guard !shuttingDown else { return .failure("温衡正在退出，不再新增处理。") }
        guard !busy else { return .failure("已有调度操作进行中，请稍后再试。") }
        guard contextStillAllows(), !process.isProtected, !process.isForeground, !process.memberIdentities.isEmpty,
              process.memberIdentities.count <= 128 else {
            return .failure("该目标受保护，或成员过多；请在应用内调整任务。")
        }
        busy = true
        defer { busy = false }
        var changed = 0
        var skipped = 0
        var skippedUnreadableScheduling = false
        var skippedNonStandardScheduling = false
        var effectSummaries: [String] = []
        for identity in process.memberIdentities {
            guard !shuttingDown, contextStillAllows() else { break }
            guard journal.count < 256 else {
                return .failure("恢复记录已达安全上限；请先撤销已有处理。已完成 \(changed) 个进程。")
            }
            guard !activeIdentities.contains(identity),
                  let raw = NativeSampler.process(pid: identity.pid),
                  ActionSafety.canLower(raw, identity: identity, app: process,
                                        foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                        foregroundBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                        protectedKeys: protectedKeysReader()) else {
                skipped += 1
                continue
            }
            // Read-back yields the actor. The target can exit, exec, become
            // foreground/protected, or shutdown can begin while it is pending.
            // No recovery intent is written until the baseline is known to be
            // safe; this prevents a failed read-back from leaving a stale
            // `taskpolicy -B` request on disk.
            applying.insert(identity)
            let before = await schedulingReader(identity.pid)
            guard !shuttingDown, !Task.isCancelled, contextStillAllows() else {
                applying.remove(identity)
                skipped += 1
                continue
            }
            // `taskpolicy -B` restores macOS's standard scheduling state, not
            // an arbitrary policy another tool may have installed.  Refuse to
            // act when the baseline cannot be read, or is already nonstandard,
            // so a reversible observation can never silently overwrite that
            // external intent.
            guard let before else {
                applying.remove(identity)
                skipped += 1
                skippedUnreadableScheduling = true
                continue
            }
            guard before.isKnownStandardBaseline else {
                applying.remove(identity)
                skipped += 1
                skippedNonStandardScheduling = true
                continue
            }
            // No additional awaited observation belongs between this check
            // and dispatch. Group members also bind their pre-readback path.
            guard let latest = NativeSampler.process(pid: identity.pid), latest.path == raw.path,
                  ActionSafety.canLower(latest, identity: identity, app: process,
                    foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    foregroundBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    protectedKeys: protectedKeysReader()) else {
                applying.remove(identity)
                skipped += 1
                continue
            }
            let entry = PolicyJournalEntry(identity: identity, displayName: process.displayName,
                createdAt: Date(), expiresAt: Date().addingTimeInterval(600),
                executablePath: raw.path, bundleIdentifier: process.bundleIdentifier)
            journal.append(entry)
            do { try persistJournal() }
            catch {
                journal.removeAll { $0.identity == identity }
                applying.remove(identity)
                return .failure("恢复记录保存失败；已停止新增优先级调整。已完成 \(changed) 个进程。")
            }
            let result = await runner(["-b", "-p", String(identity.pid)])
            applying.remove(identity)
            if result.succeeded {
                changed += 1
                let after = await schedulingReader(identity.pid)
                let evidence = PolicyEffectEvidence(before: before, after: after, observedAt: Date())
                effectEvidence[identity] = evidence
                effectSummaries.append(evidence.summary)
            } else if result.status == -2 {
                // An interrupted command can have taken effect. Keep its intent
                // and schedule restoration rather than forgetting the PID.
                retryAfter[identity] = .distantPast
                return .failure("系统调度确认超时，已停止后续处理；已完成 \(changed) 个进程，未确认项的恢复记录已保留。")
            } else {
                journal.removeAll { $0.identity == identity }
                try? persistJournal()
                skipped += 1
            }
        }
        let skippedReasons: [String] = [
            skippedUnreadableScheduling ? "有进程无法读回当前调度等级，已跳过以免覆盖未知策略" : nil,
            skippedNonStandardScheduling ? "有进程已有非标准调度等级，已跳过以免覆盖其他工具的设置" : nil
        ].compactMap { $0 }
        let safetySuffix = skippedReasons.isEmpty ? "" : " " + skippedReasons.joined(separator: "；") + "。"
        if changed > 0 {
            let uniqueSummaries = Array(Set(effectSummaries)).joined(separator: " ")
            return .success("已降低 \(process.displayName) 的 \(changed) 个进程调度优先级，跳过 \(skipped) 个；运行期间到期或回前台会恢复。" + (uniqueSummaries.isEmpty ? "" : " " + uniqueSummaries) + safetySuffix)
        }
        if !skippedReasons.isEmpty {
            return .failure("没有执行优先级调整；" + skippedReasons.joined(separator: "；") + "。")
        }
        return .failure("没有新增优先级调整：目标可能已受保护、已处理，或系统拒绝了操作。")
    }

    func restore(_ process: AppProcess) async -> ActionResult {
        await restoreEntries(journal.filter { process.memberIdentities.contains($0.identity)
            || ($0.bundleIdentifier != nil && $0.bundleIdentifier == process.bundleIdentifier) })
    }

    func restore(identity: ProcessIdentity, displayName: String = "目标进程") async -> ActionResult {
        await restoreEntries(journal.filter { $0.identity == identity })
    }

    func recoverStaleEntries() async {
        _ = await restoreEntries(journal)
    }

    /// Failed automatic restores retry at most once a minute, independently of
    /// sampling. No recursive sample -> restore -> sample feedback loop.
    func maintain(foregroundPID: pid_t?, foregroundBundle: String?, now: Date = Date()) async -> ActionResult? {
        guard !busy else { return nil }
        let due = journal.filter { entry in
            let front = entry.identity.pid == foregroundPID
                || (foregroundBundle != nil && entry.bundleIdentifier == foregroundBundle)
            return (entry.expiresAt <= now || front || retryAfter[entry.identity] != nil)
                && retryAfter[entry.identity, default: .distantPast] <= now
        }
        guard !due.isEmpty else { return nil }
        return await restoreEntries(due)
    }

    private func restoreEntries(_ entries: [PolicyJournalEntry]) async -> ActionResult {
        if let loadError { return .failure(loadError) }
        guard !busy else { return .failure("已有调度操作进行中，请稍后再试。") }
        guard !entries.isEmpty else { return .success("没有需要恢复的调度操作。") }
        busy = true
        defer { busy = false }
        var restored = 0
        var failed = 0
        for entry in entries {
            switch identityState(entry) {
            case .gone:
                journal.removeAll { $0.identity == entry.identity }
                retryAfter.removeValue(forKey: entry.identity)
                effectEvidence.removeValue(forKey: entry.identity)
            case .uncertain:
                failed += 1
                retryAfter[entry.identity] = Date().addingTimeInterval(60)
            case .same:
                let result = await runner(["-B", "-p", String(entry.identity.pid)])
                if result.succeeded {
                    journal.removeAll { $0.identity == entry.identity }
                    retryAfter.removeValue(forKey: entry.identity)
                    effectEvidence.removeValue(forKey: entry.identity)
                    restored += 1
                } else {
                    failed += 1
                    retryAfter[entry.identity] = Date().addingTimeInterval(60)
                }
            }
        }
        do { try persistJournal() }
        catch { return .failure("本次恢复已完成，但记录保存失败；下次启动会再次核验。") }
        return failed == 0
            ? .success("已恢复 \(restored) 个进程的系统标准调度；已退出的目标已从记录中移除。")
            : .failure("已恢复 \(restored) 个，另有 \(failed) 个暂未成功；已保留记录，至少 60 秒后重试。")
    }

    func restoreAllSynchronously() {
        guard loadError == nil, !quitRecoveryAttempted else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for entry in journal where !applying.contains(entry.identity) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            switch identityState(entry) {
            case .gone:
                journal.removeAll { $0.identity == entry.identity }
                effectEvidence.removeValue(forKey: entry.identity)
            case .uncertain: continue
            case .same:
                let result = CommandRunner.runSync("/usr/sbin/taskpolicy", ["-B", "-p", String(entry.identity.pid)],
                                                  timeout: max(0.05, min(0.5, remaining)))
                if result.succeeded {
                    journal.removeAll { $0.identity == entry.identity }
                    effectEvidence.removeValue(forKey: entry.identity)
                }
            }
        }
        try? persistJournal()
    }

    /// Stop queuing changes, then let a bounded in-flight command settle before
    /// undoing it. If quitting is forced, its write-ahead intent remains on disk.
    func prepareToQuit() async {
        guard !quitRecoveryAttempted else { return }
        shuttingDown = true
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while busy && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        restoreAllSynchronously()
        quitRecoveryAttempted = true
    }

    func activate(_ process: AppProcess) -> ActionResult {
        guard NativeSampler.process(pid: process.pid)?.identity == process.id,
              let app = NSRunningApplication(processIdentifier: process.pid) else {
            return .failure("应用已退出，或该进程没有可切换的窗口。")
        }
        return app.activate(options: [.activateIgnoringOtherApps])
            ? .success("已切换到 " + process.displayName + "。")
            : .failure("系统没有允许切换到该应用。")
    }

    func requestTerminate(_ process: AppProcess) -> ActionResult {
        guard !process.isSystem, !process.isProtected, !process.isForeground,
              let raw = NativeSampler.process(pid: process.pid),
              ActionSafety.canLower(raw, identity: process.id, app: process,
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                foregroundBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                protectedKeys: protectedKeysReader()),
              let app = NSRunningApplication(processIdentifier: process.pid) else {
            return .failure("目标已变化、受保护，或不支持正常退出请求。")
        }
        return app.terminate()
            ? .success("已向 " + process.displayName + " 请求正常退出；请留意应用的保存提示。")
            : .failure("应用没有接受正常退出请求。")
    }

    /// Explicit, user-confirmed last resort. Revalidates the process identity
    /// immediately before termination to narrow (not eliminate) the PID-reuse
    /// race, then requires affirmative evidence that the original task is gone.
    func forceTerminate(_ process: AppProcess, automatic: Bool = false) async -> ActionResult {
        guard !process.isSystem, !process.isProtected, !process.isForeground,
              let raw = NativeSampler.process(pid: process.pid),
              ActionSafety.canLower(raw, identity: process.id, app: process,
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                foregroundBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                protectedKeys: protectedKeysReader(), automatic: automatic) else {
            return .failure("目标已变化、受保护，或无法安全核验；没有强制结束。")
        }
        // Re-read after all UI work and immediately before resolving the
        // termination primitive. macOS has no pidfd equivalent, so this narrows
        // the PID-reuse window and the post-action identity check remains mandatory.
        guard let latest = NativeSampler.process(pid: process.pid),
              latest.identity == process.id,
              ActionSafety.canLower(latest, identity: process.id, app: process,
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                foregroundBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                protectedKeys: protectedKeysReader(), automatic: automatic) else {
            return .failure("目标在执行前已变化；没有强制结束。")
        }
        // GUI applications are routed through AppKit so they receive the
        // normal macOS termination semantics. Background helpers and command
        // line workers do not have an NSRunningApplication record; after the
        // same identity/path/UID checks above, target only that single PID.
        let requested: Bool
        // A bundle-less target is a command-line/helper task even when
        // AppKit happens to expose an NSRunningApplication wrapper for it.
        // Route it through SIGKILL so the explicit force action has the same
        // deterministic semantics for the new ephemeral-CLI scope.
        if process.bundleIdentifier == nil {
            requested = Darwin.kill(process.pid, SIGKILL) == 0
        } else if let app = NSRunningApplication(processIdentifier: process.pid) {
            requested = app.forceTerminate()
        } else {
            requested = Darwin.kill(process.pid, SIGKILL) == 0
        }
        guard requested else {
            return .failure("系统没有接受强制结束请求；没有扩大处理范围。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NativeSampler.process(pid: process.id.pid)?.isZombie == true {
                return .success("已强制结束 " + process.displayName + "；目标已退出，正在等待父进程回收；未保存工作或正在执行的任务可能已中断。")
            }
            let state = ActionVerification.state(
                expected: process.id,
                observed: NativeSampler.process(pid: process.id.pid)?.identity
            ) {
                let result = Darwin.kill(process.id.pid, 0)
                let error = errno
                return (result, error)
            }
            if state == .gone {
                return .success("已强制结束 " + process.displayName + "；未保存工作或正在执行的任务可能已中断。")
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch {
                return .failure("已发送强制结束请求，但结果核验被取消；没有确认目标已消失。")
            }
        }
        return .failure("已发送强制结束请求，但目标仍在运行或状态未知；没有扩大处理范围。")
    }

    private enum IdentityState { case same, gone, uncertain }
    private func identityState(_ entry: PolicyJournalEntry) -> IdentityState {
        if let raw = NativeSampler.process(pid: entry.identity.pid) {
            guard raw.identity == entry.identity else { return .gone }
            // exec() can change the path without replacing the kernel task.
            // Undo our own policy on that same task, never discard its intent
            // just because its executable path changed or is unreadable.
            return ActionSafety.canRestore(raw, entry: entry) ? .same : .uncertain
        }
        return Darwin.kill(entry.identity.pid, 0) == -1 && errno == ESRCH ? .gone : .uncertain
    }

    private func persistJournal() throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}

/// A failed process read is not proof of exit: libproc can be temporarily
/// unreadable, or permissions can change while the task still exists. Only a
/// different start identity or an explicit ESRCH from a signal-zero probe
/// confirms that the original task no longer exists. The probe never signals
/// a task and is skipped when its identity is already readable.
enum ActionVerification {
    enum State: Equatable { case same, gone, unknown }

    static func state(expected: ProcessIdentity, observed: ProcessIdentity?,
                      existenceProbe: () -> (result: Int32, error: Int32)) -> State {
        if let observed { return observed == expected ? .same : .gone }
        let probe = existenceProbe()
        return probe.result == -1 && probe.error == ESRCH ? .gone : .unknown
    }
}

enum ActionSafety {
    static func canRestore(_ raw: RawProcessSample, entry: PolicyJournalEntry) -> Bool {
        raw.identity == entry.identity && entry.identity.startAbstime > 0
            && entry.identity.pid > 1 && raw.uid == getuid()
    }
    static func canLower(_ raw: RawProcessSample, identity: ProcessIdentity, app: AppProcess,
                         foregroundPID: pid_t?, foregroundBundle: String?, protectedKeys: Set<String>,
                         parentLookup: (pid_t) -> pid_t? = { NativeSampler.process(pid: $0)?.parentPID },
                         automatic: Bool = false,
                         ancestryLookup: (pid_t) -> ProcessAncestryGate.Node? = { ProcessAncestryGate.readNode(pid: $0) }) -> Bool {
        guard raw.identity == identity, identity.startAbstime > 0, identity.pid > 1, identity.pid != getpid(),
              raw.uid == getuid(), app.uid == getuid(), !raw.path.isEmpty,
              !ProcessPathPolicy.isSystemExecutable(raw.path),
              !protectedKeys.contains(app.protectionKey),
              !app.memberIdentities.contains(where: { $0.pid == foregroundPID }),
              ForegroundAncestorGate.evaluate(parentPID: raw.parentPID, foregroundPID: foregroundPID,
                  ownPID: getpid(), parentLookup: parentLookup) == .clear,
              app.bundleIdentifier == nil || app.bundleIdentifier != foregroundBundle else { return false }
        let ancestry = ProcessAncestryGate.evaluate(parentPID: raw.parentPID, ownPID: getpid(),
            protectedKeys: protectedKeys, lookup: ancestryLookup)
        guard ancestry.manualBlockReason == nil,
              !automatic || ancestry.automaticBlockReason == nil else { return false }
        if automatic && LocalKnowledgeBase.isAutomaticProtectionExcluded(name: raw.name,
            path: raw.path, bundleIdentifier: app.bundleIdentifier) { return false }
        // Exec can retain PID/start time and stay inside the same app bundle.
        // Fresh single-task observations bind the exact executable; legacy
        // manual reports without that field retain the historical root check.
        if app.memberIdentities.count == 1, let executablePath = app.executablePath {
            guard raw.path == executablePath else { return false }
        }
        let expectedPath = AppResolver.appRoot(from: raw.path) ?? raw.path
        guard expectedPath == app.path else { return false }
        return !LocalKnowledgeBase.advice(name: raw.name, path: raw.path, bundleIdentifier: app.bundleIdentifier).protected
    }

}
