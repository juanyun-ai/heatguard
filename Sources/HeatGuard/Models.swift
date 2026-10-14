import AppKit
import Foundation

enum ThermalLevel: Int, CaseIterable, Codable, Comparable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
    case unknown = 4

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.sortValue < rhs.sortValue
    }

    private var sortValue: Int {
        self == .unknown ? -1 : rawValue
    }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "严重"
        case .critical: "临界"
        case .unknown: "未知"
        }
    }

    var symbol: String {
        switch self {
        case .nominal: "checkmark.circle.fill"
        case .fair: "thermometer.medium"
        case .serious: "exclamationmark.triangle.fill"
        case .critical: "flame.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var explanation: String {
        switch self {
        case .nominal:
            "macOS 没有报告热压力。芯片局部温度较高时也可能仍属正常。"
        case .fair:
            "系统开始感到热负载，适合检查是否有非预期的持续任务。"
        case .serious:
            "系统正在明显限制资源。建议保存工作并处理非必要高负载。"
        case .critical:
            "热压力已到临界。请保存工作、改善散热并停止非必要重负载。"
        case .unknown:
            "当前系统没有提供可用的公共热状态。"
        }
    }
}

enum RiskLevel: Int, Comparable, Codable, Sendable {
    case normal = 0
    case watch = 1
    case elevated = 2
    case high = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .normal: "正常活动"
        case .watch: "值得观察"
        case .elevated: "疑似异常"
        case .high: "高风险负载"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "checkmark.circle"
        case .watch: "eye"
        case .elevated: "exclamationmark.circle"
        case .high: "exclamationmark.triangle.fill"
        }
    }
}

/// Manual force termination should be discoverable as soon as a user-visible
/// high-CPU background candidate appears. This is only a presentation/intent
/// gate: ActionExecutor still re-reads the PID, start identity, UID, exact
/// executable path, parent chain, foreground state and protection rules before
/// sending any termination request.
enum ManualTerminationPolicy {
    static func canForceTerminate(_ process: AppProcess, isUserProtected: Bool,
                                  cpuThreshold: Double = 80) -> Bool {
        guard cpuThreshold.isFinite, cpuThreshold >= 0,
              process.uid == getuid(),
              !process.memberIdentities.isEmpty,
              !process.isSystem, !process.isProtected, !process.isForeground,
              !isUserProtected else { return false }
        return process.risk >= .elevated
            || (process.risk == .watch && process.cpuPercent.isFinite
                && process.cpuPercent >= cpuThreshold)
    }
}

enum AutoProtectionMode: String, CaseIterable, Codable, Sendable {
    case observe
    case advise
    case enforce

    var title: String {
        switch self {
        case .observe: "仅观察"
        case .advise: "提醒但不结束"
        case .enforce: "智能自动保护"
        }
    }

    var detail: String {
        switch self {
        case .observe: "记录证据，不主动提醒或处理。"
        case .advise: "满足异常条件时提醒你，但不会自动结束应用。"
        case .enforce: "按下方自动处置范围，在满足全部持续负载和安全门槛后自动结束；前台使用记录和高 CPU 均不代表任务可结束。"
        }
    }

}

/// Controls which targets may satisfy the final automatic-termination
/// authority gate. The default remains explicit per-running-task consent.
/// `clearIdle` is a deliberately more active, user-selected mode: an
/// ungranted target still needs a full enforce window of low-I/O/high-CPU
/// evidence and all of the existing project/system/foreground protections.
enum AutomaticTerminationScope: String, CaseIterable, Codable, Sendable {
    case explicitGrant
    case clearIdle
    /// A separately confirmed scope for a narrowly defined class of
    /// unidentified command-line workers. It is intentionally not a blanket
    /// "kill every CLI" switch: only an executable rooted in an ephemeral
    /// local directory can qualify, while project roots and known tools stay
    /// advice-only.
    case clearIdleWithEphemeralCLI

    var allowsClearIdle: Bool { self != .explicitGrant }

    var allowsEphemeralCLI: Bool { self == .clearIdleWithEphemeralCLI }

    var title: String {
        switch self {
        case .explicitGrant: "仅处理我明确授权的任务"
        case .clearIdle: "自动处理明确空转后台"
        case .clearIdleWithEphemeralCLI: "自动处理明确空转后台（含安全临时命令行）"
        }
    }

    var detail: String {
        switch self {
        case .explicitGrant:
            "未授权目标只提醒；授权只绑定当前 PID、启动身份、路径和本次运行，自动结束仍需连续低 I/O 空转证据。"
        case .clearIdle:
            "仅对有可核验应用标识的未授权目标开放：连续 20 分钟 CPU ≥80% 且磁盘/唤醒持续很低才可进入倒计时；命令行项目任务、工程、浏览器、同步和会议仍只提醒。"
        case .clearIdleWithEphemeralCLI:
            "在上一档基础上，额外允许来源为 /tmp 或系统临时目录的单一命令行任务；工程目录、用户资料目录、已知工具和前台祖先仍只提醒。"
        }
    }

    var emptyGrantSummary: String {
        switch self {
        case .explicitGrant:
            "尚未授权任务 · 自动结束不会执行"
        case .clearIdle:
            "暂无逐项授权 · 符合已确认的空转范围仍可能自动结束"
        case .clearIdleWithEphemeralCLI:
            "暂无逐项授权 · 符合已确认的空转应用和安全临时命令行仍可能自动结束"
        }
    }
}

/// Controls the final user-visible grace period after all automatic evidence
/// is complete. The cancellable default preserves a last-second escape hatch;
/// `immediate` is a separately confirmed high-risk choice and is still gated
/// by the same identity, foreground, project, temperature, CPU and low-I/O
/// checks. It is never enabled by a legacy preference or the safe preset.
enum AutomaticTerminationTiming: String, CaseIterable, Codable, Sendable {
    case cancelWindow
    case immediate

    var title: String {
        switch self {
        case .cancelWindow: "30 秒可取消（推荐）"
        case .immediate: "满足门槛后直接结束（高风险）"
        }
    }

    var detail: String {
        switch self {
        case .cancelWindow:
            "满足全部条件后先给你约 30 秒取消机会。"
        case .immediate:
            "满足全部条件后不等待取消窗口；仅适合你明确允许自动结束的空转后台。退出或重启温衡、停止自动结束后会恢复为 30 秒可取消，重新启用直接模式需要再次确认。"
        }
    }

    var isImmediate: Bool { self == .immediate }
}

struct AutoProtectionSettings: Codable, Sendable, Equatable {
    var mode: AutoProtectionMode = .observe
    var automaticTerminationScope: AutomaticTerminationScope = .explicitGrant
    var automaticTerminationTiming: AutomaticTerminationTiming = .cancelWindow
    var anomalyTemperatureCelsius: Double = 65
    var enforceTemperatureCelsius: Double = 70
    var anomalyDuration: TimeInterval = 300
    var enforceDuration: TimeInterval = 1200
    var minimumCPUPercent: Double = 80
    var recentForegroundGrace: TimeInterval = 1800
    var cooldown: TimeInterval = 1800

    init(mode: AutoProtectionMode = .observe,
         automaticTerminationScope: AutomaticTerminationScope = .explicitGrant,
         automaticTerminationTiming: AutomaticTerminationTiming = .cancelWindow,
         anomalyTemperatureCelsius: Double = 65,
         enforceTemperatureCelsius: Double = 70,
         anomalyDuration: TimeInterval = 300,
         enforceDuration: TimeInterval = 1200,
         minimumCPUPercent: Double = 80,
         recentForegroundGrace: TimeInterval = 1800,
         cooldown: TimeInterval = 1800) {
        self.mode = mode
        self.automaticTerminationScope = automaticTerminationScope
        self.automaticTerminationTiming = automaticTerminationTiming
        self.anomalyTemperatureCelsius = anomalyTemperatureCelsius
        self.enforceTemperatureCelsius = enforceTemperatureCelsius
        self.anomalyDuration = anomalyDuration
        self.enforceDuration = enforceDuration
        self.minimumCPUPercent = minimumCPUPercent
        self.recentForegroundGrace = recentForegroundGrace
        self.cooldown = cooldown
    }

    private enum CodingKeys: String, CodingKey {
        case mode, automaticTerminationScope, automaticTerminationTiming,
             anomalyTemperatureCelsius, enforceTemperatureCelsius,
             anomalyDuration, enforceDuration, minimumCPUPercent,
             recentForegroundGrace, cooldown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(AutoProtectionMode.self, forKey: .mode) ?? .observe
        automaticTerminationScope = try values.decodeIfPresent(AutomaticTerminationScope.self,
            forKey: .automaticTerminationScope) ?? .explicitGrant
        automaticTerminationTiming = try values.decodeIfPresent(AutomaticTerminationTiming.self,
            forKey: .automaticTerminationTiming) ?? .cancelWindow
        anomalyTemperatureCelsius = try values.decodeIfPresent(Double.self, forKey: .anomalyTemperatureCelsius) ?? 65
        enforceTemperatureCelsius = try values.decodeIfPresent(Double.self, forKey: .enforceTemperatureCelsius) ?? 70
        anomalyDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .anomalyDuration) ?? 300
        enforceDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .enforceDuration) ?? 1200
        minimumCPUPercent = try values.decodeIfPresent(Double.self, forKey: .minimumCPUPercent) ?? 80
        recentForegroundGrace = try values.decodeIfPresent(TimeInterval.self, forKey: .recentForegroundGrace) ?? 1800
        cooldown = try values.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? 1800
        // Legacy requireRecentForegroundHistory is deliberately ignored, even
        // when false. Missing scope stays at the safe explicit-grant default;
        // only the new, user-visible clear-idle choice can broaden authority.
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(automaticTerminationScope, forKey: .automaticTerminationScope)
        try values.encode(automaticTerminationTiming, forKey: .automaticTerminationTiming)
        try values.encode(anomalyTemperatureCelsius, forKey: .anomalyTemperatureCelsius)
        try values.encode(enforceTemperatureCelsius, forKey: .enforceTemperatureCelsius)
        try values.encode(anomalyDuration, forKey: .anomalyDuration)
        try values.encode(enforceDuration, forKey: .enforceDuration)
        try values.encode(minimumCPUPercent, forKey: .minimumCPUPercent)
        try values.encode(recentForegroundGrace, forKey: .recentForegroundGrace)
        try values.encode(cooldown, forKey: .cooldown)
    }

    var isSane: Bool {
        anomalyTemperatureCelsius >= 50 && anomalyTemperatureCelsius < enforceTemperatureCelsius
            && enforceTemperatureCelsius <= 110
            && anomalyDuration >= 60 && anomalyDuration <= 3600
            && enforceDuration >= anomalyDuration && enforceDuration <= 7200
            && minimumCPUPercent >= 40 && minimumCPUPercent <= 400
            && recentForegroundGrace >= 0 && recentForegroundGrace <= 86_400
            && cooldown >= 60 && cooldown <= 86_400
    }

    /// Destructive automation must never become more permissive than the
    /// product's published safety contract because of an old preference,
    /// hand-edited defaults, or a future settings surface. Stricter values
    /// remain intact; invalid values are left for `isSane` to fail closed.
    var hardenedForAutomaticUse: AutoProtectionSettings {
        guard isSane else { return self }
        var hardened = self
        hardened.anomalyTemperatureCelsius = max(hardened.anomalyTemperatureCelsius, 65)
        hardened.enforceTemperatureCelsius = max(hardened.enforceTemperatureCelsius, 70)
        hardened.anomalyDuration = max(hardened.anomalyDuration, 300)
        hardened.enforceDuration = max(hardened.enforceDuration, 1_200, hardened.anomalyDuration)
        hardened.minimumCPUPercent = max(hardened.minimumCPUPercent, 80)
        hardened.recentForegroundGrace = max(hardened.recentForegroundGrace, 1_800)
        hardened.cooldown = max(hardened.cooldown, 1_800)
        return hardened
    }
}

struct AutoProtectionDecision: Sendable {
    enum Kind: Sendable { case none, anomaly, countdown, enforce, blocked }
    let kind: Kind
    let process: AppProcess?
    let reason: String
}

/// Read-only progress for the automatic-protection explanation shown beside a
/// candidate. It is derived from the same evidence engine that makes the
/// decision; it is never an additional permission or a second timer.
struct AutomaticEvidenceProgress: Sendable, Equatable {
    let highCPUDuration: TimeInterval
    let idleDuration: TimeInterval
    let anomalyTemperatureDuration: TimeInterval
    let enforceTemperatureDuration: TimeInterval
    let anomalyDuration: TimeInterval
    let enforceDuration: TimeInterval
    let anomalyTemperatureCelsius: Double
    let enforceTemperatureCelsius: Double
    let minimumCPUPercent: Double
    let blockedReason: String?
    let isRelevant: Bool

    private static func clock(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        if seconds < 60 { return String(seconds) + "秒" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? String(minutes) + "分钟" : String(minutes) + "分" + String(remainder) + "秒"
    }

    var summary: String {
        guard isRelevant else { return "" }
        var parts = [
            "CPU " + Self.clock(highCPUDuration) + "/" + Self.clock(enforceDuration),
            String(format: "异常温度 %.0f°C %@/%@", anomalyTemperatureCelsius,
                   Self.clock(anomalyTemperatureDuration), Self.clock(anomalyDuration)),
            String(format: "执行温度 %.0f°C %@/%@", enforceTemperatureCelsius,
                   Self.clock(enforceTemperatureDuration), Self.clock(enforceDuration))
        ]
        // Make the low-I/O prerequisite visible even when it is still zero;
        // otherwise a granted but active task can look execution-ready while
        // the engine is deliberately waiting for idle evidence.
        parts.append("空转 " + Self.clock(idleDuration) + "/" + Self.clock(enforceDuration))
        if let blockedReason, !blockedReason.isEmpty {
            parts.append("只提醒：" + blockedReason)
        }
        return "自动证据：" + parts.joined(separator: " · ")
    }
}

struct ProcessIdentity: Hashable, Codable, Sendable {
    let pid: pid_t
    let startAbstime: UInt64
}

struct RawProcessSample: Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let cpuTimeNanoseconds: UInt64?
    let interruptWakeups: UInt64?
    let packageWakeups: UInt64?
    let diskBytes: UInt64?
    let residentBytes: UInt64?
    /// BSD `p_stat`; 5 (`SZOMB`) means the task has exited and only awaits
    /// collection by its parent. It is not runnable CPU work.
    var processStatus: UInt32 = 0

    var isZombie: Bool { processStatus == 5 }
}

struct ProcessDelta: Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let cpuPercent: Double
    let wakeupsPerSecond: Double
    let diskBytesPerSecond: Double
    let residentBytes: UInt64
    let sampleDuration: TimeInterval
    /// A missing native counter is not the same as zero activity. These flags
    /// keep the optional clear-idle policy from treating unavailable I/O data
    /// as evidence that a task is safe to end.
    var wakeupsAvailable: Bool = false
    var diskAvailable: Bool = false
}

struct AppProcess: Identifiable, Codable, Sendable {
    let id: ProcessIdentity
    let memberIdentities: [ProcessIdentity]
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    let name: String
    let displayName: String
    let bundleIdentifier: String?
    let path: String
    let cpuPercent: Double
    let wakeupsPerSecond: Double
    let diskBytesPerSecond: Double
    let residentBytes: UInt64
    let isForeground: Bool
    let isBackground: Bool
    let isSystem: Bool
    let isProtected: Bool
    let protectionReason: String?
    let isSoftLimited: Bool
    let risk: RiskLevel
    let confidence: Double
    let evidence: [String]
    let recommendation: String
    /// Exact native executable path for `id`, separate from the application
    /// root used by grouping and display. Older saved reports decode this as
    /// nil and cannot acquire automatic termination authority.
    var executablePath: String? = nil
    /// Older saved reports decode these as false. Automatic clear-idle mode
    /// requires both counters to be freshly available.
    var wakeupsAvailable: Bool = false
    var diskAvailable: Bool = false

    /// Fresh ancestry can make a generic worker part of a valuable project.
    /// Older reports remain readable; dispatch independently re-reads ancestry.
    var automaticContextBlockReason: String? = nil

    init(id: ProcessIdentity, memberIdentities: [ProcessIdentity], pid: pid_t, parentPID: pid_t,
         uid: uid_t, name: String, displayName: String, bundleIdentifier: String?, path: String,
         cpuPercent: Double, wakeupsPerSecond: Double, diskBytesPerSecond: Double,
         residentBytes: UInt64, isForeground: Bool, isBackground: Bool, isSystem: Bool,
         isProtected: Bool, protectionReason: String?, isSoftLimited: Bool, risk: RiskLevel,
         confidence: Double, evidence: [String], recommendation: String,
         executablePath: String? = nil, wakeupsAvailable: Bool = false,
         diskAvailable: Bool = false, automaticContextBlockReason: String? = nil) {
        self.id = id
        self.memberIdentities = memberIdentities
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.cpuPercent = cpuPercent
        self.wakeupsPerSecond = wakeupsPerSecond
        self.diskBytesPerSecond = diskBytesPerSecond
        self.residentBytes = residentBytes
        self.isForeground = isForeground
        self.isBackground = isBackground
        self.isSystem = isSystem
        self.isProtected = isProtected
        self.protectionReason = protectionReason
        self.isSoftLimited = isSoftLimited
        self.risk = risk
        self.confidence = confidence
        self.evidence = evidence
        self.recommendation = recommendation
        self.executablePath = executablePath
        self.wakeupsAvailable = wakeupsAvailable
        self.diskAvailable = diskAvailable
        self.automaticContextBlockReason = automaticContextBlockReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, memberIdentities, pid, parentPID, uid, name, displayName, bundleIdentifier,
             path, cpuPercent, wakeupsPerSecond, diskBytesPerSecond, residentBytes,
             isForeground, isBackground, isSystem, isProtected, protectionReason,
             isSoftLimited, risk, confidence, evidence, recommendation, executablePath,
             wakeupsAvailable, diskAvailable, automaticContextBlockReason
    }

    /// Keep reports written before the clear-idle counter gate readable. Swift's
    /// synthesized `Decodable` requires a non-optional Bool key even when the
    /// property has a default value, so missing legacy keys must be handled
    /// explicitly and remain fail-closed for automatic termination.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ProcessIdentity.self, forKey: .id)
        memberIdentities = try values.decode([ProcessIdentity].self, forKey: .memberIdentities)
        pid = try values.decode(pid_t.self, forKey: .pid)
        parentPID = try values.decode(pid_t.self, forKey: .parentPID)
        uid = try values.decode(uid_t.self, forKey: .uid)
        name = try values.decode(String.self, forKey: .name)
        displayName = try values.decode(String.self, forKey: .displayName)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        path = try values.decode(String.self, forKey: .path)
        cpuPercent = try values.decode(Double.self, forKey: .cpuPercent)
        wakeupsPerSecond = try values.decode(Double.self, forKey: .wakeupsPerSecond)
        diskBytesPerSecond = try values.decode(Double.self, forKey: .diskBytesPerSecond)
        residentBytes = try values.decode(UInt64.self, forKey: .residentBytes)
        isForeground = try values.decode(Bool.self, forKey: .isForeground)
        isBackground = try values.decode(Bool.self, forKey: .isBackground)
        isSystem = try values.decode(Bool.self, forKey: .isSystem)
        isProtected = try values.decode(Bool.self, forKey: .isProtected)
        protectionReason = try values.decodeIfPresent(String.self, forKey: .protectionReason)
        isSoftLimited = try values.decode(Bool.self, forKey: .isSoftLimited)
        risk = try values.decode(RiskLevel.self, forKey: .risk)
        confidence = try values.decode(Double.self, forKey: .confidence)
        evidence = try values.decode([String].self, forKey: .evidence)
        recommendation = try values.decode(String.self, forKey: .recommendation)
        executablePath = try values.decodeIfPresent(String.self, forKey: .executablePath)
        wakeupsAvailable = try values.decodeIfPresent(Bool.self, forKey: .wakeupsAvailable) ?? false
        diskAvailable = try values.decodeIfPresent(Bool.self, forKey: .diskAvailable) ?? false
        automaticContextBlockReason = try values.decodeIfPresent(String.self, forKey: .automaticContextBlockReason)
    }

    var cpuCores: Double { cpuPercent / 100 }

    var protectionKey: String { bundleIdentifier ?? path }

    /// Standalone processes sharing an executable are separate observations.
    var groupKey: String {
        if let bundleIdentifier { return "bundle:" + bundleIdentifier }
        if let root = AppResolver.appRoot(from: path) { return "app:" + root }
        return "process:\(id.pid):\(id.startAbstime)"
    }

    func withCPU(_ value: Double, evidence: [String]? = nil) -> AppProcess {
        AppProcess(id: id, memberIdentities: memberIdentities, pid: pid, parentPID: parentPID,
                   uid: uid, name: name, displayName: displayName, bundleIdentifier: bundleIdentifier,
                   path: path, cpuPercent: value, wakeupsPerSecond: wakeupsPerSecond,
                   diskBytesPerSecond: diskBytesPerSecond, residentBytes: residentBytes,
                   isForeground: isForeground, isBackground: isBackground, isSystem: isSystem,
                   isProtected: isProtected, protectionReason: protectionReason, isSoftLimited: isSoftLimited,
                   risk: risk, confidence: confidence, evidence: evidence ?? self.evidence, recommendation: recommendation,
                   executablePath: executablePath, wakeupsAvailable: wakeupsAvailable,
                   diskAvailable: diskAvailable, automaticContextBlockReason: automaticContextBlockReason)
    }
}

struct HostPoint: Identifiable, Codable, Sendable {
    var id = UUID()
    let date: Date
    let cpuPercent: Double
    let thermal: ThermalLevel
    var temperature: Double? = nil
    var topApplication: String? = nil
}

struct DiagnosticReport: Codable, Sendable, Identifiable {
    var id: Date { date }
    let date: Date
    let duration: TimeInterval
    let thermal: ThermalLevel
    let hostCPUPercent: Double
    let candidates: [AppProcess]
    let summary: String
    var coverageNote: String = "常驻采样覆盖当前用户的可读取进程；系统进程可通过按需深扫补充。"
}

struct HostTicks: Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

enum ActionResult: Sendable {
    case success(String)
    case failure(String)
}

/// Read-back of the scheduler state after an explicit policy action. This is
/// collected on demand, not during periodic sampling, so the monitor stays
/// cheap while the user can still see whether the action had an observable
/// effect.
struct SchedulingObservation: Sendable, Equatable {
    let priority: Int
    let nice: Int
    let state: String
    /// Darwin task-policy fields are optional for older systems or denied
    /// process reads. They are read only after an explicit action; ordinary
    /// `ps` fields remain the compatibility fallback.
    let darwinPolicy: Int?
    let darwinPriority: Int?
    let darwinMaxPriority: Int?
    let darwinThreadCount: Int?
    let darwinReadableThreads: Int?
    let darwinBackgroundThreads: Int?

    init(priority: Int, nice: Int, state: String,
         darwinPolicy: Int? = nil, darwinPriority: Int? = nil,
         darwinMaxPriority: Int? = nil, darwinThreadCount: Int? = nil,
         darwinReadableThreads: Int? = nil, darwinBackgroundThreads: Int? = nil) {
        self.priority = priority
        self.nice = nice
        self.state = state
        self.darwinPolicy = darwinPolicy
        self.darwinPriority = darwinPriority
        self.darwinMaxPriority = darwinMaxPriority
        self.darwinThreadCount = darwinThreadCount
        self.darwinReadableThreads = darwinReadableThreads
        self.darwinBackgroundThreads = darwinBackgroundThreads
    }

    /// On supported macOS releases `taskpolicy -b` moves the task's maximum
    /// priority to the Darwin-background floor (currently 4), while `ps pri`
    /// may remain 31. Treat that state as already backgrounded so a second
    /// user action cannot overwrite an existing background policy.
    var schedulerReadbackComplete: Bool {
        guard let threadCount = darwinThreadCount, let readable = darwinReadableThreads else { return true }
        return threadCount > 0 && readable == threadCount
    }

    var isDarwinBackground: Bool {
        guard schedulerReadbackComplete,
              let readable = darwinReadableThreads,
              let background = darwinBackgroundThreads else { return false }
        return readable > 0 && background == readable
    }

    /// `taskpolicy -b` is only reversible to the system baseline when the
    /// target was already at macOS's normal scheduler priority.  A different
    /// priority may have been deliberately set by another tool or by the
    /// user; treating it as a safe baseline would let `-B` overwrite that
    /// intent later.
    var isKnownStandardBaseline: Bool {
        schedulerReadbackComplete && priority == 31 && !isDarwinBackground
    }
}

struct PolicyEffectEvidence: Sendable, Equatable {
    let before: SchedulingObservation?
    let after: SchedulingObservation?
    let observedAt: Date

    var summary: String {
        guard let before, let after else {
            return "已请求后台调度；系统未提供可读优先级回读，CPU 与温度不会必然立即下降。"
        }
        if before.isDarwinBackground {
            return "目标原本已处于 macOS 后台调度；没有重复覆盖已有策略。"
        }
        if after.isDarwinBackground {
            let detail: String
            if let beforeBackground = before.darwinBackgroundThreads,
               let beforeReadable = before.darwinReadableThreads,
               let afterBackground = after.darwinBackgroundThreads,
               let afterReadable = after.darwinReadableThreads {
                detail = "后台线程回读 " + String(beforeBackground) + "/" + String(beforeReadable)
                    + "→" + String(afterBackground) + "/" + String(afterReadable)
            } else if let beforeMax = before.darwinMaxPriority, let afterMax = after.darwinMaxPriority {
                detail = "后台调度回读 " + String(beforeMax) + "→" + String(afterMax)
            } else {
                detail = "后台调度状态已回读"
            }
            return detail + "；仅在资源争用时让步，不是 CPU 硬限速。"
        }
        if before.priority == after.priority {
            return "已请求后台调度；回读优先级未变化（目标可能本来就是后台等级）。"
        }
        return "回读调度优先级 \(before.priority)→\(after.priority)；仅在争用时让步，不是 CPU 硬限速。"
    }
}

/// A single in-memory outcome kept visible after a reversible scheduling
/// action is restored. It is intentionally not Codable and never becomes a
/// history stream: the user gets a useful answer without adding resident
/// sampling or persisting process details beyond the existing local events.
struct PolicyFeedback: Sendable, Equatable {
    let date: Date
    let displayName: String
    /// Stable in-memory link back to the process group whose observation is
    /// being shown. It lets a restore action close a still-pending card
    /// without persisting process details or guessing from the display name.
    let groupKey: String
    /// The scheduler read-back is kept next to the CPU/temperature result so
    /// the overview can answer the first question users have: did macOS
    /// accept the reversible hint? It is optional because older in-memory
    /// feedback or a failed read-back must remain representable.
    let effectSummary: String?
    let summary: String
    let explanation: String
    let pending: Bool
    let remainsHigh: Bool
    let cancelled: Bool
    let interrupted: Bool
}

struct KnowledgeAdvice: Sendable {
    let explanation: String
    let recommendation: String
    let protected: Bool
}

/// A presentation-only activity signature. It helps the user distinguish a
/// tight loop from an obviously I/O-heavy job; it is never an execution
/// permission and never bypasses the explicit automatic-termination grant.
enum ActivitySignature {
    /// Availability is explicit in production. The defaults keep this small
    /// pure helper convenient for deterministic fixtures; the automatic
    /// policy passes native counter availability and therefore fails closed.
    static func lowIOHighCPU(cpuPercent: Double, diskBytesPerSecond: Double,
                             wakeupsPerSecond: Double, diskAvailable: Bool = true,
                             wakeupsAvailable: Bool = true) -> Bool {
        diskAvailable && wakeupsAvailable && cpuPercent.isFinite && cpuPercent >= 80
            && diskBytesPerSecond.isFinite && diskBytesPerSecond < 1_048_576
            && wakeupsPerSecond.isFinite && wakeupsPerSecond < 500
    }

    static func highIODuringCPU(diskBytesPerSecond: Double, wakeupsPerSecond: Double) -> Bool {
        (diskBytesPerSecond.isFinite && diskBytesPerSecond >= 1_048_576)
            || (wakeupsPerSecond.isFinite && wakeupsPerSecond >= 500)
    }
}

/// Paths under `/usr/local` are commonly user-installed tools (Homebrew on
/// Intel Macs, local helper binaries). They remain eligible only when the
/// process also belongs to the current user; the rest of `/usr` and `/System`
/// stay protected as operating-system locations.
enum ProcessPathPolicy {
    static func isSystemExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !normalized.isEmpty else { return true }
        if normalized == "/usr/local" || normalized.hasPrefix("/usr/local/") {
            return false
        }
        return normalized == "/System"
            || normalized.hasPrefix("/System/")
            || normalized == "/usr"
            || normalized.hasPrefix("/usr/")
    }
}

enum LocalKnowledgeBase {
    private static let automaticExclusionNames: Set<String> = [
        "xcode", "xcodebuild", "swift", "swiftc", "swift-driver",
        "swift-frontend", "swiftfrontend", "swiftcompile", "clang", "clang++", "clangd",
        "sourcekit", "sourcekit-lsp", "sourcekitd", "sourcekitservice", "xcbbuildservice",
        "terminal", "iterm", "iterm2", "ghostty", "alacritty", "kitty", "wezterm",
        "code", "cursor", "zed", "idea", "pycharm", "clion", "webstorm", "rider",
        "cargo", "rustc", "rust-analyzer", "ninja", "make", "gmake",
        "gradle", "gradlew", "cmake", "bazel", "msbuild", "javac", "kotlinc",
        "maven", "mvn", "ant", "dotnet", "gcc", "g++", "ld", "ld64",
        "metal", "ibtool", "actool", "dsymutil",
        // Common user-started project/media/AI workers. They remain visible
        // and manually controllable, but a generic CLI name is not enough
        // evidence that an unattended kill is safe.
        "python", "python3", "node", "nodejs", "deno", "bun", "ffmpeg",
        "blender", "handbrake", "docker", "dockerd", "podman", "ollama",
        "rclone", "rsync", "git", "git-lfs", "java", "ruby", "perl",
        "qemu-system", "codex", "codexpro", "openclaw", "qclaw",
        "chrome", "chromium", "safari", "firefox", "edge", "brave",
        "arc", "opera", "vivaldi", "electron", "webkit", "webview",
        "wechat", "weixin", "slack", "discord", "telegram", "zoom",
        "teams", "webex", "dingtalk", "tencentmeeting", "qq"
    ]

    /// Build and indexing workers are often intentionally compute-bound for
    /// long periods. They remain visible and can still be ended explicitly by
    /// the user, but automatic protection must never mistake them for an idle
    /// background task.
    static func isAutomaticProtectionExcluded(name: String, path: String,
                                               bundleIdentifier: String?) -> Bool {
        let fields = [name, path, bundleIdentifier ?? ""].map { $0.lowercased() }
        for field in fields {
            let basename = URL(fileURLWithPath: field).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if automaticExclusionNames.contains(basename) { return true }
            let tokens = field.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if tokens.contains(where: automaticExclusionNames.contains) { return true }
        }
        return false
    }

    /// A deliberately narrow escape hatch for the separately confirmed
    /// command-line scope. Without an application bundle there is no general
    /// way to infer business value from a process name, so only an executable
    /// whose observed path is itself rooted in an ephemeral local directory is
    /// eligible. Project/user-data roots and app-like paths remain advice-only.
    static func isEphemeralCommandLineTarget(name: String, path: String,
                                             bundleIdentifier: String?, executablePath: String?) -> Bool {
        guard bundleIdentifier == nil, let executablePath,
              !path.isEmpty, path == executablePath,
              (executablePath as NSString).isAbsolutePath,
              !executablePath.contains("\0") else { return false }
        let observedURL = URL(fileURLWithPath: executablePath)
        let normalized = observedURL.standardizedFileURL.path
        let resolved = observedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let ephemeralRoots = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/"]
        // Check both spellings. A symlink in /tmp must not turn a project
        // executable into an apparently disposable worker. If the path does
        // not exist yet, Foundation keeps the resolved spelling equal to the
        // observed one and the normal strict identity checks still apply.
        guard normalized != "/", resolved != "/",
              ephemeralRoots.contains(where: { normalized.hasPrefix($0) }),
              ephemeralRoots.contains(where: { resolved.hasPrefix($0) }) else { return false }

        // Keep the mode from becoming a back door for a copied project or a
        // source/build tree placed under a temporary parent.
        let projectTokens: Set<String> = [
            "desktop", "documents", "downloads", "project", "projects", "workspace", "workspaces",
            "repo", "repos", "repository", "repositories", "source", "src", ".git", "deriveddata",
            "node_modules", "venv", "virtualenv", "build", "dist"
        ]
        let components = normalized.lowercased().split(separator: "/").map(String.init)
        let resolvedComponents = resolved.lowercased().split(separator: "/").map(String.init)
        guard !components.contains(where: projectTokens.contains),
              !resolvedComponents.contains(where: projectTokens.contains) else { return false }
        // The name is checked here as well because a temporary copy of a
        // known long-running tool is still not safe to classify by path alone.
        return !isAutomaticProtectionExcluded(name: name, path: normalized, bundleIdentifier: nil)
            && !isAutomaticProtectionExcluded(name: name, path: resolved, bundleIdentifier: nil)
    }

    static func advice(name: String, path: String, bundleIdentifier: String?) -> KnowledgeAdvice {
        let key = "\(name) \(path) \(bundleIdentifier ?? "")".lowercased()

        if key.contains("kernel_task") {
            return KnowledgeAdvice(
                explanation: "kernel_task 可能正在帮助 macOS 管理热量，它通常是结果而不是根因。",
                recommendation: "不要结束它。回看高温前几分钟的应用负载，并改善通风。",
                protected: true
            )
        }
        if key.contains("windowserver") {
            return KnowledgeAdvice(
                explanation: "WindowServer 负责窗口合成；高占用常与外接显示器、动画、屏幕共享或频繁重绘有关。",
                recommendation: "关闭不需要的窗口或屏幕共享，检查外接显示器刷新率，再观察是否下降。",
                protected: true
            )
        }
        if key.contains("mdworker") || key.contains("/mds") {
            return KnowledgeAdvice(
                explanation: "这是 Spotlight 索引任务，首次同步或大量文件变化后会暂时繁忙。",
                recommendation: "通常等待完成即可；若长期重复，检查 Spotlight 隐私设置与异常磁盘。",
                protected: true
            )
        }
        if key.contains("photoanalysisd") {
            return KnowledgeAdvice(
                explanation: "照片正在进行本地人物、场景等分析，接电或新导入照片后较常见。",
                recommendation: "让 Mac 接电并空闲一段时间；不建议强制结束系统分析服务。",
                protected: true
            )
        }
        if key.contains("mediaanalysisd") || key.contains("mediaanalysis") {
            return KnowledgeAdvice(
                explanation: "媒体分析服务正在处理视频、音频或视觉内容，导入媒体、系统升级或首次索引后可能持续占用 CPU。",
                recommendation: "先让分析自然完成并保持通风；检查照片/媒体导入队列，非必要时暂停来源任务，不要强制结束系统分析服务。",
                protected: true
            )
        }
        if key.contains("applicationsstorageextension") || key.contains("storagemanagement") {
            return KnowledgeAdvice(
                explanation: "系统存储管理扩展正在计算应用、文件或磁盘分类，打开存储设置、清理大文件或系统迁移时可能短时繁忙。",
                recommendation: "等待存储分类完成并关闭不需要的存储管理窗口；若长期反复，稍后重启 Finder 或再检查磁盘状态，不要强制结束系统扩展。",
                protected: true
            )
        }
        if key.contains("backupd") || key.contains("time machine") {
            return KnowledgeAdvice(
                explanation: "Time Machine 正在备份，可能同时产生 CPU 与磁盘负载。",
                recommendation: "让备份完成，或从菜单栏暂时停止本次备份。",
                protected: true
            )
        }
        if key.contains("bird") || key.contains("cloudd") {
            return KnowledgeAdvice(
                explanation: "云盘同步可能在校验或上传大量文件。",
                recommendation: "检查云盘同步状态与反复失败的文件，不要直接结束系统同步服务。",
                protected: true
            )
        }
        if key.contains("xcode") || key.contains("swift") || key.contains("clang") || key.contains("sourcekit") {
            return KnowledgeAdvice(
                explanation: "这看起来像编译、索引或代码分析任务，短时多核占用通常符合预期。",
                recommendation: "确认是否正在构建或索引；非预期时先在开发工具里取消任务。",
                protected: false
            )
        }
        if key.contains("chrome") || key.contains("safari") || key.contains("firefox") || key.contains("browser") {
            return KnowledgeAdvice(
                explanation: "浏览器标签页、扩展、视频或网页脚本可能持续占用 CPU。",
                recommendation: "先用浏览器任务管理器定位标签页或扩展；不必退出整个浏览器。",
                protected: false
            )
        }
        if key.contains("zoom") || key.contains("teams") || key.contains("facetime") || key.contains("obs.app") || key.contains("webex") || key.contains("dingtalk") || key.contains("voov") || key.contains("tencentmeeting") {
            return KnowledgeAdvice(
                explanation: "音视频通话、录制或屏幕共享会产生持续负载，而且可能有未保存内容。",
                recommendation: "先确认会议或录制是否正在进行；工具不会自动干预它。",
                protected: true
            )
        }
        return KnowledgeAdvice(
            explanation: "该进程持续贡献 CPU；工具无法仅凭资源使用判断计算是否有用。",
            recommendation: "先切换到应用确认任务状态。若确属后台空转，可降低调度优先级 10 分钟并观察；这不是 CPU 硬限速。",
            protected: false
        )
    }
}

enum SamplingMode: String, CaseIterable, Identifiable {
    case adaptive, quiet
    var id: String { rawValue }
    var title: String { self == .adaptive ? "自适应" : "极省电" }
    var detail: String { self == .adaptive ? "使用面板时约 5 秒；普通后台约 60 秒，高热或自动保护时加密采样。" : "使用面板时约 10 秒；后台约 60 秒。启用自动结束后后台最多 30 秒；倒计时会临时加密采样。" }
}

/// Full process enumeration is the expensive part of resident monitoring. Keep
/// its cadence independent from the temperature reader: thermal pressure may
/// justify a fresh sensor read, but it must never make the monitor enumerate
/// every 5–10 seconds while hidden and add heat of its own.
enum SamplingCadencePolicy {
    static func interval(mode: SamplingMode, automaticMode: AutoProtectionMode,
                         thermal: ThermalLevel, active: Bool,
                         scanning: Bool, countdown: Bool) -> TimeInterval {
        if scanning { return mode == .quiet ? 5 : 2.5 }
        if countdown { return 5 }
        if automaticMode == .enforce {
            // Automatic evidence needs a fresh process frame within the
            // 45-second execution gate; 30 seconds is sufficient while
            // hidden, including serious/critical thermal pressure.
            return active ? (mode == .quiet ? 10 : 5) : 30
        }
        if mode == .quiet { return active ? 10 : 60 }
        if thermal >= .serious {
            return active ? (mode == .quiet ? 10 : 5) : 30
        }
        return active ? 5 : 60
    }
}

struct ActivityEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    let date: Date
    let message: String
}

extension Double {
    var percentText: String { String(format: "%.1f%%", self) }
    var coreText: String { String(format: "%.2f 核", self) }
}

extension UInt64 {
    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .memory)
    }
}
