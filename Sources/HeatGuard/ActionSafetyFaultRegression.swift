import Darwin

/// Pure input fault matrix for the shared pre-dispatch `canLower` gate.
/// No files, processes, signals, settings, or application registrations are
/// created or changed. Parent-chain cases stop before native process lookup.
/// This does NOT exercise the UI, ActionExecutor's outer guards, dispatch,
/// post-termination verification, or a multi-hop live ancestor chain.
enum ActionSafetyFaultRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let baseline = Input()
        let positiveControl = allows(baseline)
        var results: [(name: String, passed: Bool)] = [
            ("动作共用门禁：阳性对照允许当前用户的后台同一身份", positiveControl)
        ]

        // Every rejection also requires the unchanged fixture to pass. A
        // broken fixture or an always-false gate cannot make this matrix green.
        func reject(_ name: String, _ change: (inout Input) -> Void) {
            var fault = baseline
            change(&fault)
            results.append(("动作共用门禁：" + name, positiveControl && !allows(fault)))
        }

        reject("拒绝原始 PID 与目标身份不同") {
            $0.rawIdentity = ProcessIdentity(pid: $0.otherPID, startAbstime: $0.identity.startAbstime)
        }
        reject("拒绝 PID 复用后的不同启动时间") {
            $0.rawIdentity = ProcessIdentity(pid: $0.identity.pid, startAbstime: $0.identity.startAbstime + 1)
        }
        reject("拒绝相同 PID 但陈旧的请求启动时间") {
            $0.identity = ProcessIdentity(pid: $0.identity.pid, startAbstime: $0.identity.startAbstime + 1)
        }
        reject("拒绝启动时间缺失的相同身份") {
            $0.replaceIdentity(ProcessIdentity(pid: $0.identity.pid, startAbstime: 0))
        }
        reject("拒绝 PID 零") { $0.replaceIdentity(ProcessIdentity(pid: 0, startAbstime: 100)) }
        reject("拒绝 launchd PID 一") { $0.replaceIdentity(ProcessIdentity(pid: 1, startAbstime: 100)) }
        reject("拒绝负 PID") { $0.replaceIdentity(ProcessIdentity(pid: -1, startAbstime: 100)) }
        reject("拒绝监控器自身 PID") { $0.replaceIdentity(ProcessIdentity(pid: getpid(), startAbstime: 100)) }
        reject("拒绝原始进程属于其他用户") { $0.rawUID = foreignUID() }
        reject("拒绝应用快照属于其他用户") { $0.appUID = foreignUID() }
        reject("拒绝缺失的原始可执行路径") { $0.rawPath = "" }
        reject("拒绝快照中的其他应用根路径") { $0.appPath = "/private/tmp/HeatGuardOtherWorker.app" }
        reject("拒绝快照中的空应用根路径") { $0.appPath = "" }
        reject("拒绝同 bundle 同身份但 exec 换成另一可执行文件") {
            $0.rawPath = Input.root + "/Contents/MacOS/replacement"
        }
        reject("拒绝精确可执行路径的大小写变化") { $0.executablePath = Input.root + "/Contents/MacOS/WORKER" }
        reject("拒绝空的精确可执行路径") { $0.executablePath = "" }
        reject("拒绝用户按 bundle 标识保护的目标") { $0.protectedKeys = [$0.bundleIdentifier!] }
        reject("拒绝用户按独立进程路径保护的目标") {
            $0.bundleIdentifier = nil
            $0.usePath("/private/tmp/heatguard-action-worker")
            $0.protectedKeys = [$0.appPath]
        }
        reject("拒绝当前前台主成员") { $0.foregroundPID = $0.identity.pid }
        reject("拒绝同组另一个成员位于前台") {
            let other = ProcessIdentity(pid: $0.otherPID, startAbstime: 200)
            $0.members.append(other)
            $0.foregroundPID = other.pid
        }
        reject("拒绝直接父进程就是前台任务的后台子进程") {
            $0.parentPID = $0.otherPID
            $0.foregroundPID = $0.otherPID
        }
        reject("拒绝同 bundle 的前台应用") { $0.foregroundBundle = $0.bundleIdentifier }

        // Keep identity, expected path and exact executable consistent: these
        // failures therefore cover system path policy, not a root mismatch.
        reject("拒绝 System 目录中的可执行文件") { $0.usePath("/System/Library/heatguard-action-worker") }
        reject("拒绝 System 根路径") { $0.usePath("/System") }
        reject("拒绝 usr bin 目录中的可执行文件") { $0.usePath("/usr/bin/heatguard-action-worker") }
        reject("拒绝 usr libexec 目录中的可执行文件") { $0.usePath("/usr/libexec/heatguard-action-worker") }
        reject("拒绝 usr 根路径") { $0.usePath("/usr") }
        reject("拒绝 usr local 点点逃逸到系统目录") { $0.usePath("/usr/local/../bin/heatguard-action-worker") }
        reject("拒绝伪装成 usr local 的相似前缀") { $0.usePath("/usr/local-tools/heatguard-action-worker") }

        // These retain a non-system executable path; the knowledge-base
        // protection itself must deny them rather than the path guard.
        reject("拒绝内核任务知识库保护") { $0.rawName = "kernel_task" }
        reject("拒绝窗口服务知识库保护") { $0.rawName = "WindowServer" }
        reject("拒绝索引任务知识库保护") { $0.rawName = "mdworker_shared" }
        reject("拒绝照片分析知识库保护") { $0.rawName = "photoanalysisd" }
        reject("拒绝备份任务知识库保护") { $0.rawName = "backupd" }
        reject("拒绝云同步任务知识库保护") { $0.rawName = "cloudd" }
        reject("拒绝会议 bundle 知识库保护") { $0.bundleIdentifier = "us.zoom.xos" }

        // Boundary controls prevent over-broad prefix, nil-bundle, or
        // ancestor guards from silently turning into deny-everything rules.
        var localTool = baseline
        localTool.bundleIdentifier = nil
        localTool.usePath("/usr/local/bin/heatguard-action-worker")
        results.append(("动作共用门禁：阳性对照允许用户安装的 usr local 工具", allows(localTool)))

        var unrelatedForeground = baseline
        unrelatedForeground.foregroundPID = baseline.otherPID
        unrelatedForeground.foregroundBundle = "example.unrelated.frontmost"
        results.append(("动作共用门禁：阳性对照允许与前台无关且父 PID 为一的目标", allows(unrelatedForeground)))

        var ownHelper = baseline
        ownHelper.parentPID = getpid()
        ownHelper.foregroundPID = getpid()
        results.append(("动作共用门禁：阳性对照在自身测试父进程处停止祖先检查", allows(ownHelper)))

        var ancestry = baseline
        ancestry.parentPID = baseline.otherPID
        ancestry.foregroundPID = getpid()
        let readableChain = allows(ancestry, parentLookup: { _ in 1 })
        results.append(("动作共用门禁：阳性对照允许完整查到 launchd 的父链", readableChain))
        results.append(("动作共用门禁：父链不可读必须拒绝而非假定与前台无关",
                        readableChain && !allows(ancestry, parentLookup: { _ in nil })))
        results.append(("动作共用门禁：父链循环必须拒绝",
                        readableChain && !allows(ancestry, parentLookup: { $0 })))
        results.append(("动作共用门禁：父链返回无效 PID 必须拒绝",
                        readableChain && !allows(ancestry, parentLookup: { _ in 0 })))
        return results
    }

    private static func foreignUID() -> uid_t { getuid() == 0 ? 1 : 0 }

    private static func allows(_ input: Input, parentLookup: (pid_t) -> pid_t? = { _ in nil }) -> Bool {
        let raw = RawProcessSample(identity: input.rawIdentity, parentPID: input.parentPID,
            uid: input.rawUID, name: input.rawName, path: input.rawPath,
            cpuTimeNanoseconds: 1, interruptWakeups: 0, packageWakeups: 0, diskBytes: 0, residentBytes: 0)
        let app = AppProcess(id: input.identity, memberIdentities: input.members,
            pid: input.identity.pid, parentPID: input.parentPID, uid: input.appUID,
            name: "worker", displayName: "Pure action safety fixture", bundleIdentifier: input.bundleIdentifier,
            path: input.appPath, cpuPercent: 150, wakeupsPerSecond: 0, diskBytesPerSecond: 0,
            residentBytes: 0, isForeground: false, isBackground: true, isSystem: false,
            isProtected: false, protectionReason: nil, isSoftLimited: false, risk: .high,
            confidence: 1, evidence: ["pure input fixture"], recommendation: "test only",
            executablePath: input.executablePath)
        return ActionSafety.canLower(raw, identity: input.identity, app: app,
            foregroundPID: input.foregroundPID, foregroundBundle: input.foregroundBundle,
            protectedKeys: input.protectedKeys, parentLookup: parentLookup,
            ancestryLookup: { pid in
                parentLookup(pid).map {
                    ProcessAncestryGate.Node(identity: ProcessIdentity(pid: pid, startAbstime: 1),
                        parentPID: $0, uid: getuid(), name: "fixture-parent", path: "/tmp/fixture-parent")
                }
            })
    }

    private struct Input {
        static let root = "/private/tmp/HeatGuardActionWorker.app"
        var identity: ProcessIdentity
        var rawIdentity: ProcessIdentity
        var members: [ProcessIdentity]
        let otherPID: pid_t
        var parentPID: pid_t = 1
        var rawUID = getuid()
        var appUID = getuid()
        var rawName = "worker"
        var rawPath = Input.root + "/Contents/MacOS/worker"
        var appPath = Input.root
        var executablePath: String? = Input.root + "/Contents/MacOS/worker"
        var bundleIdentifier: String? = "example.heatguard.actionworker"
        var foregroundPID: pid_t?
        var foregroundBundle: String?
        var protectedKeys: Set<String> = []

        init() {
            // Synthetic values need not exist; no native PID lookup occurs.
            // Avoid assuming that any hard-coded fixture PID is not our own.
            let candidates = [pid_t.max, pid_t.max - 1, pid_t.max - 2].filter { $0 != getpid() }
            identity = ProcessIdentity(pid: candidates[0], startAbstime: 100)
            rawIdentity = identity
            members = [identity]
            otherPID = candidates[1]
        }

        mutating func replaceIdentity(_ replacement: ProcessIdentity) {
            identity = replacement
            rawIdentity = replacement
            members = [replacement]
        }

        mutating func usePath(_ path: String) {
            rawPath = path
            executablePath = path
            appPath = AppResolver.appRoot(from: path) ?? path
        }
    }
}
