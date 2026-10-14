import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
    @Published private(set) var temperature: TemperatureReading?
    @Published private(set) var hostCPUPercent: Double = 0
    @Published private(set) var loadAverage: Double = 0
    @Published private(set) var processes: [AppProcess] = []
    @Published private(set) var history: [HostPoint] = []
    @Published private(set) var thermalExposure: [ThermalExposureDay] = []
    @Published private(set) var reportHistory: [DiagnosticReport] = []
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var report: DiagnosticReport?
    @Published private(set) var statusMessage = "正在建立本地基线…"
    @Published private(set) var lastSampleDate: Date?
    @Published private(set) var lastSampleCostMilliseconds: Double = 0
    @Published private(set) var totalProcessCount = 0
    @Published private(set) var readableProcessCount = 0
    @Published private(set) var ownCPUPercent: Double = 0
    @Published private(set) var ownMemoryBytes: UInt64 = 0
    @Published private(set) var activePolicies: [PolicyJournalEntry] = []
    @Published private(set) var policyEffectEvidence: [ProcessIdentity: PolicyEffectEvidence] = [:]
    @Published private(set) var policyCPUObservations: [String: PolicyCPUObservation] = [:]
    @Published private(set) var lastPolicyFeedback: PolicyFeedback?
    @Published private(set) var isActionBusy = false
    @Published private(set) var autoProtectionStatus = "自动保护未启用"
    @Published private(set) var autoProtectionCountdownActive = false
    @Published private(set) var automaticSessionConfirmed = false
    @Published private(set) var protectedApps: [String: String] = [:]
    // Explicit grants are intentionally memory-only and identify one running
    // task, not every future executable with the same name or installation path.
    @Published private(set) var automaticTerminationGrants: [AutomaticTerminationGrant: String] = [:]
    @Published var pendingAutomaticPermission: AppProcess?
    @Published var showAutomaticPermissionConfirmation = false
    @Published private(set) var bulkTargets: [AppProcess] = []
    @Published var diagnosticDuration: Double = 30
    @Published var samplingMode: SamplingMode {
        didSet {
            // Keep diagnostic/test instances isolated from the installed app.
            // Production still passes UserDefaults.standard explicitly.
            preferences.set(samplingMode.rawValue, forKey: "samplingMode")
            if ready { schedule(after: 1) }
        }
    }
    @Published var pendingTermination: AppProcess?
    @Published var pendingForceTermination: AppProcess?
    @Published var pendingSoftLimit: AppProcess?
    @Published var showTerminationConfirmation = false
    @Published var showForceTerminationConfirmation = false
    @Published var showAutoProtectionConfirmation = false
    @Published var showSafeIdleAutomationConfirmation = false
    @Published var showAutomaticScopeConfirmation = false
    @Published var showAutomaticTimingConfirmation = false
    @Published private(set) var pendingAutomaticTerminationScope: AutomaticTerminationScope?
    @Published private(set) var pendingAutomaticPolicyConfirmation: AutomaticPolicyConfirmation?
    @Published var showSoftLimitConfirmation = false
    @Published var showBulkReview = false
    @Published var showClearHistoryConfirmation = false
    @Published var launchAtLogin = false
    @Published var autoProtectionSettings: AutoProtectionSettings {
        didSet {
            // A policy/threshold edit starts a fresh evidence epoch. This
            // prevents enabling destructive automation from immediately
            // inheriting minutes accumulated while the app was only
            // observing (or from a now-different threshold).
            dismissAutomaticPolicyConfirmation()
            revokeAutomaticProtection()
            automaticSettingsWriter(autoProtectionSettings)
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet { preferences.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    private let worker = MonitoringWorker()
    private let store: LocalStore
    private let actions: ActionExecutor
    private let preferences: HeatGuardPreferences
    private var timer: Timer?
    private var ready = false
    private var sessionGate = ProtectionSessionGate()
    private let sessionSnapshot: () -> ProtectionSessionSnapshot
    private let automaticSettingsWriter: (AutoProtectionSettings) -> Void
    private var sleeping: Bool { sessionGate.isPaused }
    private var sampling = false
    private var refreshRequested = false
    private var baselineReset = false
    private var fullReset = false
    private var generation = 0
    private var previousResultDate: Date?
    private var scanStartedAt: Date?
    private var scanStartUptime: TimeInterval = 0
    private var scanDuration: TimeInterval = 30
    private var scanAccumulator = ScanAccumulator()
    private var deepScanTask: Task<Void, Never>?
    private var temperatureRefreshInFlight = false
    private var lastTemperatureRefresh = Date.distantPast
    private var lastPersist = Date.distantPast
    private var lastExposurePoint: HostPoint?
    private var lastAutoScan = Date.distantPast
    private var transientUntil = Date.distantPast
    private var ignoredUntil: [String: Date] = [:]
    private var policyMaintenance = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var automaticProtection = AutomaticProtectionEngine()
    private var lastAutoNotice = Date.distantPast
    private var autoCountdownKey: String?
    private var autoActionEpoch: UInt64 = 0
    private var autoCountdownDeadlineUptime: TimeInterval?
    private let countdownNotice: any AutomaticCountdownPresenting
    private let automaticClock: AutomaticProtectionClock
    private var dashboardOpener: (@MainActor () -> Void)?

    var topProcesses: [AppProcess] {
        TopProcessSelector.select(processes, ignoredUntil: ignoredUntil, now: Date())
    }
    /// Resolve a feedback card back to the current process frame. The view may
    /// offer a manual force-end shortcut, but the action entry still performs
    /// its normal fresh-sample, identity and protection checks.
    func process(for groupKey: String) -> AppProcess? {
        processes.first { $0.groupKey == groupKey }
    }
    var actionableProcesses: [AppProcess] {
        topProcesses.filter { !$0.isSystem && !$0.isProtected && !$0.isForeground && !$0.isSoftLimited
            && !isUserProtected($0) && $0.risk >= .elevated }
    }
    var monitoringCoverageText: String {
        "CPU 可读 \(readableProcessCount)/\(totalProcessCount) 个进程；不可读项不按零占用处理，可按需深扫补充。"
    }
    var samplingDetail: String {
        samplingMode.detail + (lastSampleDate.map { " 最近采样 " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
    }
    var thermalColor: NSColor {
        switch thermal {
        case .nominal: .systemGreen
        case .fair: .systemOrange
        case .serious, .critical: .systemRed
        case .unknown: .secondaryLabelColor
        }
    }

    init(autoStart: Bool = true, dataDirectory: URL? = nil,
         sessionSnapshot: @escaping () -> ProtectionSessionSnapshot = { .read() },
         initialAutomaticSettings: AutoProtectionSettings? = nil,
         automaticSettingsWriter: ((AutoProtectionSettings) -> Void)? = nil,
         preferences: HeatGuardPreferences = UserDefaults.standard,
         automaticClock: AutomaticProtectionClock = .system,
         countdownNotice: (any AutomaticCountdownPresenting)? = nil) {
        self.sessionSnapshot = sessionSnapshot
        self.preferences = preferences
        self.automaticClock = automaticClock
        self.countdownNotice = countdownNotice ?? CountdownNoticeController()
        self.automaticSettingsWriter = automaticSettingsWriter ?? { settings in
            if let data = try? JSONEncoder().encode(settings) {
                preferences.set(data, forKey: "autoProtectionSettings")
            }
        }
        samplingMode = preferences.string(forKey: "samplingMode").flatMap(SamplingMode.init(rawValue:)) ?? .adaptive
        notificationsEnabled = preferences.object(forKey: "notificationsEnabled") as? Bool ?? false
        if let settings = initialAutomaticSettings, settings.isSane {
            autoProtectionSettings = settings.mode == .enforce ? settings.hardenedForAutomaticUse : settings
        } else if let data = preferences.data(forKey: "autoProtectionSettings"),
           let saved = try? JSONDecoder().decode(AutoProtectionSettings.self, from: data), saved.isSane {
            // Apply the safety floor before any unlock event can confirm the
            // session. A persisted high-risk no-cancel choice is deliberately
            // downgraded to the cancellable default on every launch: session
            // confirmation is not a substitute for the separate direct-mode
            // confirmation. The user can opt in again from the current UI.
            var loaded = saved.mode == .enforce ? saved.hardenedForAutomaticUse : saved
            if loaded.mode == .enforce {
                loaded.automaticTerminationTiming = .cancelWindow
            }
            autoProtectionSettings = loaded
        } else {
            autoProtectionSettings = AutoProtectionSettings()
        }
        store = LocalStore(file: dataDirectory?.appendingPathComponent("history-v2.json"))
        let preferencesForActions = preferences
        actions = ActionExecutor(journalURL: dataDirectory?.appendingPathComponent("actions-v1.json"),
            protectedKeysReader: {
                Set(preferencesForActions.stringArray(forKey: "protectedBundleIDs") ?? [])
            })
        protectedApps = preferences.dictionary(forKey: "protectedAppNames") as? [String: String] ?? [:]
        for key in preferences.stringArray(forKey: "protectedBundleIDs") ?? [] {
            if protectedApps[key] == nil { protectedApps[key] = key }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        addObserver(ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            Task { @MainActor in self?.thermalDidChange() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        addObserver(NSWorkspace.willSleepNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        }
        addObserver(NSWorkspace.didWakeNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
        addObserver(NSWorkspace.screensDidSleepNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(.displaySleep, inactive: true) }
        }
        addObserver(NSWorkspace.sessionDidResignActiveNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(.sessionInactive, inactive: true) }
        }
        addObserver(NSWorkspace.screensDidWakeNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(.displaySleep, inactive: false) }
        }
        addObserver(NSWorkspace.sessionDidBecomeActiveNotification, center: workspaceCenter) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(.sessionInactive, inactive: false) }
        }
        let distributedCenter = DistributedNotificationCenter.default()
        addObserver(Notification.Name("com.apple.screenIsLocked"), center: distributedCenter) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(.screenLocked, inactive: true) }
        }
        addObserver(Notification.Name("com.apple.screenIsUnlocked"), center: distributedCenter) { [weak self] _ in
            Task { @MainActor in self?.screenDidUnlock() }
        }
        addObserver(NSWorkspace.didActivateApplicationNotification, center: workspaceCenter) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                self?.applicationBecameActive(pid: pid)
                self?.maintainPolicies()
            }
        }
        addObserver(NSApplication.willTerminateNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.actions.restoreAllSynchronously() }
        }
        // Notifications do not replay sleep/session events that happened
        // before launch. Public console/display state supplements them, but
        // is not proof that an already-lit screen is unlocked.
        let initialSession = sessionSnapshot()
        if initialSession.onConsole == false || initialSession.loginDone == false {
            sessionGate.set(.sessionInactive, inactive: true)
        }
        if initialSession.anyDisplayAwake == false {
            sessionGate.set(.displaySleep, inactive: true)
        }
        if autoStart {
            Task { [weak self] in
                guard let self else { return }
                let saved = await self.store.load()
                self.history = saved.points
                self.thermalExposure = saved.thermalExposure
                self.reportHistory = saved.reports
                self.events = saved.events
                self.report = saved.reports.last
                await self.actions.recoverStaleEntries()
                self.syncPolicies()
                self.ready = true
                if let issue = self.actions.recoveryIssue { self.recordEvent(issue) }
                if let issue = await self.store.recoveryIssue { self.recordEvent(issue) }
                await self.sampleNow()
                self.schedule(after: 2)
            }
        }
    }

    deinit {
        timer?.invalidate()
        deepScanTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    func sampleNowFromUI() {
        guard ready else { return }
        timer?.invalidate()
        Task { [weak self] in await self?.sampleNow() }
    }

    func prepareForTermination() async {
        ready = false
        dismissAutomaticPolicyConfirmation()
        cancelAutomaticPermission()
        revokeAutomaticProtection()
        timer?.invalidate()
        deepScanTask?.cancel()
        statusMessage = "正在恢复调度并退出…"
        await actions.prepareToQuit()
    }

    func beginDiagnostic(duration: TimeInterval? = nil) {
        guard ready, !sleeping, !isScanning else { return }
        revokeAutomaticProtection()
        isScanning = true
        scanProgress = 0
        scanStartedAt = Date()
        scanStartUptime = ProcessInfo.processInfo.systemUptime
        scanDuration = max(10, min(duration ?? diagnosticDuration, 300))
        scanAccumulator = ScanAccumulator()
        previousResultDate = nil
        // A new interval baseline avoids counting work before the button click,
        // while the analyzer retains minutes of already-observed evidence.
        baselineReset = true
        statusMessage = "正在观察当前负载，请照常工作。"
        sampleNowFromUI()
    }

    func cancelDiagnostic() {
        deepScanTask?.cancel()
        deepScanTask = nil
        isScanning = false
        scanProgress = 0
        scanStartedAt = nil
        scanAccumulator = ScanAccumulator()
        showStatus("排查已取消；菜单栏监控继续运行。")
        if ready { schedule(after: nextInterval()) }
    }

    func isUserProtected(_ process: AppProcess) -> Bool { protectedApps[process.protectionKey] != nil }
    func protect(_ process: AppProcess) {
        guard !process.protectionKey.isEmpty else { return }
        let protectedProcesses = processes.filter { $0.protectionKey == process.protectionKey }
        automaticTerminationGrants = automaticTerminationGrants.filter { grant, _ in
            !grant.matches(process: process) && !protectedProcesses.contains(where: { grant.matches(process: $0) })
        }
        protectedApps[process.protectionKey] = process.displayName
        saveProtection()
        if actions.activeIdentities.isDisjoint(with: process.memberIdentities) {
            recordEvent("已保护 " + process.displayName + "，今后不列入处理候选。")
            sampleNowFromUI()
        } else { restore(process) }
    }
    func removeProtection(_ key: String) {
        protectedApps.removeValue(forKey: key)
        saveProtection()
        sampleNowFromUI()
    }
    private func saveProtection() {
        preferences.set(Array(protectedApps.keys), forKey: "protectedBundleIDs")
        preferences.set(protectedApps, forKey: "protectedAppNames")
        // A protection edit must take effect immediately, not after a worker
        // finishes its next sample. Removing a protection also starts a new
        // evidence epoch rather than inheriting a previous candidate's timer.
        revokeAutomaticProtection()
        autoProtectionStatus = "保护名单已更新：自动保护将重新积累连续证据。"
    }

    func hasAutomaticPermission(_ process: AppProcess) -> Bool {
        guard let grant = AutomaticTerminationGrant(process: process) else { return false }
        return automaticTerminationGrants[grant] != nil
    }

    /// The card explanation is read-only and comes from the same policy
    /// ledger as automatic decisions. It intentionally stays hidden while
    /// the product is in quiet observe mode.
    func automaticEvidence(for process: AppProcess) -> AutomaticEvidenceProgress? {
        guard autoProtectionSettings.mode != .observe else { return nil }
        return automaticProtection.evidence(for: process, now: automaticClock.now(),
            settings: autoProtectionSettings,
            authorizedTargets: Set(automaticTerminationGrants.keys))
    }

    func canAllowAutomaticTermination(_ process: AppProcess) -> Bool {
        process.uid == getuid() && process.isBackground && !process.isForeground
            && !process.isSystem && !process.isProtected && !isUserProtected(process)
            && process.automaticContextBlockReason == nil
            && !process.isSoftLimited && AutomaticTerminationGrant(process: process) != nil
            && !LocalKnowledgeBase.isAutomaticProtectionExcluded(
                name: process.name, path: process.path, bundleIdentifier: process.bundleIdentifier)
            && !LocalKnowledgeBase.isAutomaticProtectionExcluded(
                name: process.name, path: process.executablePath ?? "", bundleIdentifier: process.bundleIdentifier)
    }

    func askToAllowAutomaticTermination(_ process: AppProcess) {
        guard canAllowAutomaticTermination(process), !isActionBusy else { return }
        pendingAutomaticPermission = process
        showAutomaticPermissionConfirmation = true
    }

    func cancelAutomaticPermission() {
        pendingAutomaticPermission = nil
        showAutomaticPermissionConfirmation = false
    }

    func confirmAutomaticPermission() {
        let pending = pendingAutomaticPermission
        cancelAutomaticPermission()
        guard let pending, let grant = AutomaticTerminationGrant(process: pending),
              let lastSampleDate, (0...90).contains(automaticClock.now().timeIntervalSince(lastSampleDate)),
              let latest = processes.first(where: { grant.matches(process: $0) }),
              canAllowAutomaticTermination(latest), !isActionBusy else {
            showStatus("目标已变化或采样过期，未授予自动结束权限；请重新采样并核对。")
            return
        }
        automaticTerminationGrants[grant] = latest.displayName
        revokeAutomaticProtection()
        autoProtectionStatus = "本次运行已授权：重新积累 20 分钟证据；不会立即结束，也不会自动开启保护策略。"
        recordEvent("已允许本次运行自动结束：\(latest.displayName)（PID \(latest.pid)）；退出、重启、路径变化或温衡退出后失效。")
    }

    func removeAutomaticPermission(_ grant: AutomaticTerminationGrant) {
        guard let name = automaticTerminationGrants.removeValue(forKey: grant) else { return }
        revokeAutomaticProtection()
        autoProtectionStatus = "本次授权已撤销，待执行动作已取消。"
        recordEvent("已撤销本次自动结束授权：" + name + "。")
    }

    func removeAllAutomaticPermissions() {
        guard !automaticTerminationGrants.isEmpty else { return }
        automaticTerminationGrants.removeAll()
        revokeAutomaticProtection()
        autoProtectionStatus = "所有本次授权已撤销，待执行动作已取消。"
        recordEvent(autoProtectionStatus)
    }

    private func pruneAutomaticPermissions() {
        guard !automaticTerminationGrants.isEmpty else { return }
        let live = Set(processes.filter { !$0.isProtected && !isUserProtected($0) }
            .compactMap { AutomaticTerminationGrant(process: $0) })
        let retained = automaticTerminationGrants.filter { live.contains($0.key) }
        guard retained.count != automaticTerminationGrants.count else { return }
        automaticTerminationGrants = retained
        revokeAutomaticProtection()
    }

    func askToSoften(_ process: AppProcess) {
        // Keep the UI and the action layer aligned: system executables are
        // never candidates for a user-initiated scheduling change. Without
        // this guard the confirmation sheet could open only to fail later,
        // which makes a "one-click" action look unreliable.
        guard !process.isSystem, !process.isProtected, !process.isForeground,
              !isUserProtected(process), !isActionBusy else { return }
        pendingSoftLimit = process
        showSoftLimitConfirmation = true
    }
    func confirmSoften() {
        guard let process = pendingSoftLimit else { return }
        showSoftLimitConfirmation = false
        pendingSoftLimit = nil
        runAction { await self.softenWithFeedback(process) }
    }
    func restore(_ process: AppProcess) {
        let groupKey = process.groupKey
        runAction {
            let result = await self.actions.restore(process)
            if case .success = result { self.markPolicyFeedbackCancelled(groupKey: groupKey) }
            return result
        }
    }
    func restorePolicy(_ entry: PolicyJournalEntry) {
        let groupKey = policyCPUObservations.first { $0.value.appliedIdentities.contains(entry.identity) }?.key
        runAction {
            let result = await self.actions.restore(identity: entry.identity, displayName: entry.displayName)
            if case .success = result, let groupKey { self.markPolicyFeedbackCancelled(groupKey: groupKey) }
            return result
        }
    }
    func softLimitEvidence(for process: AppProcess) -> String? {
        process.memberIdentities.lazy.compactMap { self.policyEffectEvidence[$0]?.summary }.first
    }
    func softLimitObservation(for process: AppProcess) -> PolicyCPUObservation? {
        guard let value = policyCPUObservations[process.groupKey], value.matches(process) else { return nil }
        return value
    }
    private func softenWithFeedback(_ process: AppProcess) async -> ActionResult {
        guard let process = currentManualActionTarget(process) else {
            return .failure("处理已取消：最新采样已过期、目标已变化或受保护，请重新核对。")
        }
        let previousPolicies = actions.activeIdentities
        let before = processes.first { $0.id == process.id && $0.path == process.path
            && $0.executablePath == process.executablePath
            && Set($0.memberIdentities) == Set(process.memberIdentities) }
        let sampleDate = before == nil ? nil : lastSampleDate
        let sampleTemperatureCelsius = before == nil ? nil : temperature?.celsius
        let sampleTemperatureDate = before == nil ? nil : temperature?.date
        let result = await actions.soften(process, confirmed: true, contextStillAllows: { [weak self] in
            self?.currentManualActionTarget(process) != nil
        })
        let applied = actions.activeIdentities.subtracting(previousPolicies)
            .intersection(Set(actions.activeEffectEvidence.keys))
        if let observation = PolicyCPUObservation(process: before ?? process,
            sampleDate: sampleDate, sampleTemperatureCelsius: sampleTemperatureCelsius,
            sampleTemperatureDate: sampleTemperatureDate,
            applied: applied, startedAt: Date()) {
            // The action journal caps active identities at 256. No histories
            // or per-sample arrays are retained for this feedback.
            policyCPUObservations[process.groupKey] = observation
            if case .success = result {
                let effectSummary = applied.compactMap { actions.activeEffectEvidence[$0]?.summary }.first
                lastPolicyFeedback = PolicyFeedback(
                    date: Date(),
                    displayName: process.displayName,
                    groupKey: process.groupKey,
                    effectSummary: effectSummary,
                    summary: observation.summary,
                    explanation: observation.explanation,
                    pending: !observation.isComplete,
                    remainsHigh: observation.remainsHigh,
                    cancelled: false,
                    interrupted: false)
            }
        }
        return result
    }
    func softLimitExpiry(for process: AppProcess) -> Date? {
        activePolicies.filter { entry in
            process.memberIdentities.contains(entry.identity)
                || (entry.bundleIdentifier != nil && entry.bundleIdentifier == process.bundleIdentifier)
        }.map(\.expiresAt).min()
    }
    func activate(_ process: AppProcess) { present(actions.activate(process)) }
    func askToTerminate(_ process: AppProcess) {
        guard !process.isSystem, !process.isProtected, !process.isForeground,
              !isUserProtected(process), !isActionBusy else { return }
        pendingTermination = process
        showTerminationConfirmation = true
    }
    func confirmTermination() {
        guard let process = pendingTermination else { return }
        pendingTermination = nil
        showTerminationConfirmation = false
        runAction {
            guard let latest = self.currentManualActionTarget(process) else {
                return .failure("退出已取消：最新采样已过期、目标已变化或受保护，请重新核对。")
            }
            return self.actions.requestTerminate(latest)
        }
    }
    func askToForceTerminate(_ process: AppProcess) {
        guard canForceTerminate(process), !isActionBusy else { return }
        pendingForceTermination = process
        showForceTerminationConfirmation = true
    }
    func canForceTerminate(_ process: AppProcess) -> Bool {
        ManualTerminationPolicy.canForceTerminate(process, isUserProtected: isUserProtected(process))
    }
    func confirmForceTermination() {
        guard let process = pendingForceTermination else { return }
        pendingForceTermination = nil
        showForceTerminationConfirmation = false
        runAction {
            guard let latest = self.currentManualActionTarget(process), self.canForceTerminate(latest) else {
                return .failure("强制结束已取消：最新采样已过期、目标已变化或受保护，请重新核对。")
            }
            return await self.actions.forceTerminate(latest)
        }
    }

    /// Confirmation sheets and bulk review can outlive the frame that opened
    /// them. Re-resolve the same task immediately inside the queued action;
    /// native ancestry alone cannot recover an already-detached protected
    /// parent. The latest analyzer result owns that remembered association.
    private func currentManualActionTarget(_ requested: AppProcess) -> AppProcess? {
        guard ready, !sleeping, let lastSampleDate,
              (0...90).contains(automaticClock.now().timeIntervalSince(lastSampleDate)),
              let latest = processes.first(where: { $0.groupKey == requested.groupKey }),
              latest.id == requested.id, latest.path == requested.path,
              latest.executablePath != nil, latest.executablePath == requested.executablePath,
              Set(latest.memberIdentities) == Set(requested.memberIdentities),
              !latest.isSystem, !latest.isProtected, !latest.isForeground,
              !isUserProtected(latest), latest.uid == getuid() else { return nil }
        return latest
    }

    /// Changing to automatic termination is an intentionally explicit action.
    /// The picker calls this instead of mutating the setting directly so a
    /// user cannot enable destructive automation by an accidental selection.
    func setAutoProtectionMode(_ mode: AutoProtectionMode) {
        guard mode != autoProtectionSettings.mode else {
            if mode != .enforce { dismissAutomaticPolicyConfirmation() }
            return
        }
        if mode == .enforce {
            beginAutomaticPolicyConfirmation(.enableMode)
            showAutoProtectionConfirmation = true
            return
        }
        var settings = autoProtectionSettings
        settings.mode = mode
        // Leaving destructive mode also forgets the high-risk no-cancel
        // choice. Re-entering enforcement therefore cannot silently inherit
        // direct termination after a stop or a downgrade to advice.
        settings.automaticTerminationTiming = .cancelWindow
        autoProtectionSettings = settings
        autoProtectionStatus = mode == .observe
            ? "自动保护：仅观察，不会自动结束应用。"
            : "自动保护：只提醒，不会自动结束应用。"
        recordEvent("自动保护策略已切换为：" + mode.title + "。")
    }

    /// One explicit, user-visible preset for the product's intended hands-off
    /// mode. The old two-picker flow could leave the user in `.enforce` with
    /// the default `.explicitGrant` scope, which is safe but feels broken:
    /// automatic protection was enabled while no ungranted task could ever be
    /// ended. This preset keeps the default observe-only startup, then makes
    /// the requested safe-idle policy a single confirmed action.
    func askToEnableSafeIdleAutomation() {
        guard !isActionBusy else { return }
        guard autoProtectionSettings.mode != .enforce
            || !autoProtectionSettings.automaticTerminationScope.allowsClearIdle else { return }
        beginAutomaticPolicyConfirmation(.safeIdle)
        showSafeIdleAutomationConfirmation = true
    }

    func confirmSafeIdleAutomation(_ confirmation: AutomaticPolicyConfirmation) {
        guard consumeAutomaticPolicyConfirmation(confirmation, intent: .safeIdle) else { return }
        var settings = autoProtectionSettings.hardenedForAutomaticUse
        settings.automaticTerminationScope = .clearIdle
        settings.automaticTerminationTiming = .cancelWindow
        settings.mode = .enforce
        // Assign once so persistence and the evidence reset happen as one
        // policy transition rather than briefly exposing a half-enabled mode.
        autoProtectionSettings = settings
        automaticSessionConfirmed = true
        revokeAutomaticProtection()
        autoProtectionStatus = "安全空转自动保护已启用：满足全部门槛的单一后台应用可进入30秒取消倒计时。"
        recordEvent("已启用安全空转自动保护：从零累计温度、CPU 与低 I/O 证据。")
    }

    private func beginAutomaticPolicyConfirmation(_ intent: AutomaticPolicyConfirmation.Intent) {
        dismissAutomaticPolicyConfirmation()
        pendingAutomaticPolicyConfirmation = AutomaticPolicyConfirmation(intent: intent, settings: autoProtectionSettings)
    }

    private func dismissAutomaticPolicyConfirmation() {
        pendingAutomaticPolicyConfirmation = nil
        showSafeIdleAutomationConfirmation = false
        showAutoProtectionConfirmation = false
        showAutomaticScopeConfirmation = false
        showAutomaticTimingConfirmation = false
        pendingAutomaticTerminationScope = nil
    }

    func cancelAutomaticPolicyConfirmation(_ confirmation: AutomaticPolicyConfirmation) {
        // A late cancel from a superseded alert must not dismiss a newer one.
        guard pendingAutomaticPolicyConfirmation == confirmation else { return }
        dismissAutomaticPolicyConfirmation()
    }

    private func consumeAutomaticPolicyConfirmation(_ confirmation: AutomaticPolicyConfirmation,
        intent: AutomaticPolicyConfirmation.Intent) -> Bool {
        guard pendingAutomaticPolicyConfirmation == confirmation,
              confirmation.intent == intent, confirmation.settings == autoProtectionSettings else { return false }
        dismissAutomaticPolicyConfirmation()
        guard !sleeping, sessionSnapshot().isInteractive, autoProtectionSettings.isSane else {
            automaticSessionConfirmed = false
            revokeAutomaticProtection()
            autoProtectionStatus = "会话或设置未能核验，未更改自动处置许可；请解锁后重新确认。"
            return false
        }
        return true
    }

    /// Selecting the more active clear-idle scope is itself a destructive
    /// policy change, so it gets a separate confirmation and never piggybacks
    /// on the mode picker. The default explicit-grant scope stays reversible
    /// and can be selected immediately.
    func setAutomaticTerminationScope(_ scope: AutomaticTerminationScope) {
        guard scope != autoProtectionSettings.automaticTerminationScope else {
            if !scope.allowsClearIdle { dismissAutomaticPolicyConfirmation() }
            return
        }
        if scope.allowsClearIdle {
            beginAutomaticPolicyConfirmation(.changeScope(scope))
            pendingAutomaticTerminationScope = scope
            showAutomaticScopeConfirmation = true
            return
        }
        pendingAutomaticTerminationScope = nil
        showAutomaticScopeConfirmation = false
        var settings = autoProtectionSettings
        settings.automaticTerminationScope = .explicitGrant
        settings.automaticTerminationTiming = .cancelWindow
        autoProtectionSettings = settings
        autoProtectionStatus = "自动处置范围：只处理你明确授权的任务；未授权后台只提醒。"
        recordEvent("自动处置范围已收紧为：只处理明确授权任务。")
    }

    func confirmAutomaticScopeEnable(_ confirmation: AutomaticPolicyConfirmation) {
        guard case .changeScope(let scope) = confirmation.intent, scope.allowsClearIdle,
              consumeAutomaticPolicyConfirmation(confirmation, intent: .changeScope(scope)) else { return }
        var settings = autoProtectionSettings
        if settings.mode == .enforce {
            settings = settings.hardenedForAutomaticUse
        }
        settings.automaticTerminationScope = scope
        autoProtectionSettings = settings
        revokeAutomaticProtection()
        autoProtectionStatus = "自动处置范围：\(scope.title)；重要任务仍需加入保护名单。"
        recordEvent("已启用更主动的自动处置范围：\(scope.title)。")
    }

    /// Immediate automatic termination is deliberately a separate, high-risk
    /// policy choice. It is available only after the user has selected an
    /// automatic clear-idle scope; changing it from the safe 30-second default
    /// can never happen through a legacy preference or a picker side effect.
    func setAutomaticTerminationTiming(_ timing: AutomaticTerminationTiming) {
        guard timing != autoProtectionSettings.automaticTerminationTiming else {
            if !timing.isImmediate { dismissAutomaticPolicyConfirmation() }
            return
        }
        if timing.isImmediate {
            guard autoProtectionSettings.mode == .enforce,
                  autoProtectionSettings.automaticTerminationScope.allowsClearIdle else {
                showStatus("直接自动结束只对已确认的空转自动处置范围开放；请先启用安全空转范围。")
                return
            }
            beginAutomaticPolicyConfirmation(.changeTiming(timing))
            showAutomaticTimingConfirmation = true
            return
        }
        autoProtectionSettings.automaticTerminationTiming = .cancelWindow
        autoProtectionStatus = "自动结束保留 30 秒取消窗口。"
        recordEvent("自动结束方式已收紧为：30 秒可取消。")
    }

    func cancelAutomaticTimingConfirmation(_ confirmation: AutomaticPolicyConfirmation) {
        guard pendingAutomaticPolicyConfirmation == confirmation else { return }
        dismissAutomaticPolicyConfirmation()
    }

    func confirmAutomaticTimingEnable(_ confirmation: AutomaticPolicyConfirmation) {
        guard case .changeTiming(let timing) = confirmation.intent, timing.isImmediate,
              consumeAutomaticPolicyConfirmation(confirmation, intent: .changeTiming(timing)),
              autoProtectionSettings.automaticTerminationScope.allowsClearIdle else { return }
        var settings = autoProtectionSettings.hardenedForAutomaticUse
        settings.automaticTerminationTiming = .immediate
        autoProtectionSettings = settings
        revokeAutomaticProtection()
        autoProtectionStatus = "高风险直接自动结束已启用：仅对满足全部门槛的空转后台执行，不再等待 30 秒。"
        recordEvent("已启用高风险直接自动结束；温度、CPU、低 I/O、身份和关键任务保护仍必须全部通过。")
    }

    /// One-way, immediate safety control. Unlike cancelling one incident, this
    /// falls back to advice without turning on notifications the user disabled,
    /// preserves an already-quiet observe mode, cancels pending prompts, and
    /// revokes queued execution without stopping normal monitoring. It never
    /// waits for an in-flight action: a signal already sent cannot be undone.
    func stopAutomaticTermination() {
        dismissAutomaticPolicyConfirmation()
        cancelAutomaticPermission()
        automaticSessionConfirmed = false
        if autoProtectionSettings.mode == .enforce {
            setAutoProtectionMode(.advise)
        } else {
            revokeAutomaticProtection()
        }
        autoProtectionStatus = autoProtectionSettings.mode == .advise
            ? "自动结束已停止；监测和异常提醒保留。重新启用需再次确认。"
            : "自动结束已停止；保留仅观察，不主动提醒。重新启用需再次确认。"
    }

    func confirmAutoProtectionEnable(_ confirmation: AutomaticPolicyConfirmation) {
        guard consumeAutomaticPolicyConfirmation(confirmation, intent: .enableMode) else { return }
        var settings = autoProtectionSettings.hardenedForAutomaticUse
        settings.mode = .enforce
        // Entering destructive mode is not the confirmation for the separate
        // high-risk direct-timing choice. Always start with the cancellable
        // default; the user can opt into direct termination in its own alert.
        settings.automaticTerminationTiming = .cancelWindow
        autoProtectionSettings = settings
        confirmAutomaticProtectionForSession()
        recordEvent("已启用智能自动保护：仅对满足全部安全门槛的后台主进程自动结束。")
    }

    /// Called only from an explicit local UI action, never from onAppear,
    /// app activation, startup, or a timer (all can occur behind a lock screen).
    func confirmAutomaticProtectionForSession() {
        guard !sleeping, sessionSnapshot().isInteractive else {
            automaticSessionConfirmed = false
            revokeAutomaticProtection()
            autoProtectionStatus = "会话或显示器状态未能确认，自动结束保持暂停。"
            return
        }
        if autoProtectionSettings.mode == .enforce {
            let hardened = autoProtectionSettings.hardenedForAutomaticUse
            if hardened != autoProtectionSettings {
                autoProtectionSettings = hardened
            }
        }
        automaticSessionConfirmed = true
        revokeAutomaticProtection()
        autoProtectionStatus = "本次会话已确认：自动保护从零积累连续证据。"
    }

    func ignore(_ process: AppProcess, for duration: TimeInterval = 3600) {
        ignoredUntil[process.groupKey] = Date().addingTimeInterval(duration)
        showStatus("已暂时隐藏 " + process.displayName + "，1 小时后自动恢复显示。")
    }
    func resetIgnored() {
        ignoredUntil.removeAll()
        showStatus("已恢复所有暂时隐藏的应用。")
    }
    func prepareBulkReview() {
        bulkTargets = Array(actionableProcesses.prefix(3))
        showBulkReview = true
    }
    func applySafeBulkActions() {
        let targets = bulkTargets
        showBulkReview = false
        guard !targets.isEmpty else { return }
        runAction {
            var successes = 0
            var issues: [String] = []
            for target in targets {
                switch await self.softenWithFeedback(target) {
                case .success: successes += 1
                case .failure(let message): issues.append(target.displayName + "：" + message)
                }
            }
            let message = "已处理 \(successes)/\(targets.count) 个候选应用；恢复入口见安全设置。"
            return issues.isEmpty ? .success(message) : .failure(message + " " + issues.joined(separator: " "))
        }
    }
    @discardableResult
    private func runAction(_ operation: @escaping @MainActor () async -> ActionResult) -> Task<Void, Never>? {
        guard !isActionBusy, !policyMaintenance else { showStatus("正在完成上一项操作，请稍候。"); return nil }
        isActionBusy = true
        return Task {
            let result = await operation()
            syncPolicies()
            isActionBusy = false
            present(result)
            sampleNowFromUI()
        }
    }
    private func present(_ result: ActionResult) {
        switch result {
        case .success(let message), .failure(let message): recordEvent(message)
        }
    }
    private func syncPolicies() {
        activePolicies = actions.activeEntries
        policyEffectEvidence = actions.activeEffectEvidence
        if !policyCPUObservations.isEmpty {
            let active = actions.activeIdentities
            policyCPUObservations = policyCPUObservations.filter { $0.value.appliedIdentities.isSubset(of: active) }
        }
    }
    private func maintainPolicies() {
        guard ready, !isActionBusy, !policyMaintenance, !actions.activeEntries.isEmpty else { return }
        policyMaintenance = true
        let front = NSWorkspace.shared.frontmostApplication
        Task {
            let result = await actions.maintain(foregroundPID: front?.processIdentifier,
                                              foregroundBundle: front?.bundleIdentifier)
            syncPolicies()
            policyMaintenance = false
            if let result { present(result) }
        }
    }

    private func applicationBecameActive(pid: pid_t?) {
        // A brief switch between sampling ticks is still user intent. Cancel
        // any queued action, but retain unrelated targets' countdown deadline
        // and evidence rather than restarting every timer on every app switch.
        autoActionEpoch &+= 1
        guard let pid, let raw = NativeSampler.process(pid: pid),
              let process = processes.first(where: { $0.memberIdentities.contains(raw.identity) }) else { return }
        guard process.id == raw.identity, process.executablePath == raw.path else { return }
        automaticProtection.recordForegroundUse(process, at: automaticClock.now())
        if autoCountdownKey == process.groupKey {
            invalidateAutomaticAction()
            countdownNotice.dismiss()
            autoProtectionCountdownActive = false
            autoCountdownKey = nil
            autoProtectionStatus = "你刚切换到该应用：已取消自动结束，并重新进入最近使用保护期。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            showStatus(SMAppService.mainApp.status == .requiresApproval
                ? "请在系统设置 → 通用 → 登录项中批准温衡。"
                : (launchAtLogin ? "已设置登录时启动。" : "已关闭登录时启动。"))
        } catch { showStatus("登录项设置失败：" + error.localizedDescription) }
    }
    func requestNotificationPermission() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                if !granted { self?.showStatus("通知未获授权；可在系统设置中开启，应用内监控仍可使用。") }
                if let error { self?.showStatus("通知设置失败：" + error.localizedDescription) }
            }
        }
    }

    func saveLatestReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "温衡排查-" + Self.fileDateFormatter.string(from: report.date) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ReportExporter.markdown(report).write(to: url, atomically: true, encoding: .utf8)
                self?.recordEvent("报告已保存到 " + url.lastPathComponent)
            } catch { self?.showStatus("报告保存失败：" + error.localizedDescription) }
        }
    }
    func selectReport(_ value: DiagnosticReport) { report = value }
    func clearLocalHistory() {
        history.removeAll()
        thermalExposure.removeAll()
        lastExposurePoint = nil
        reportHistory.removeAll()
        events.removeAll()
        report = nil
        lastPolicyFeedback = nil
        showStatus("已清除温衡趋势、热暴露账本与报告历史；调度恢复记录继续保留。")
        persistNow()
    }

    private func sampleNow() async {
        guard ready, !sleeping else { return }
        guard !sampling else { refreshRequested = true; return }
        if !baselineReset, !fullReset, let lastSampleDate {
            let sinceLast = Date().timeIntervalSince(lastSampleDate)
            // A wall-clock rollback must not starve the monitor until the
            // clock catches up. The worker will reject the first mismatched
            // delta via its monotonic/wall-time guard and rebuild a baseline.
            if sinceLast >= 0 && sinceLast < 0.5 {
                schedule(after: 1)
                return
            }
        }
        sampling = true
        timer?.invalidate()
        let epoch = generation
        if fullReset {
            fullReset = false
            baselineReset = false
            await worker.reset()
            automaticProtection.invalidateEvidence()
        } else if baselineReset {
            baselineReset = false
            await worker.resetBaseline()
        }
        let result = await worker.sample(context: makeAnalysisContext(), limited: actions.activeIdentities)
        if !sleeping, epoch == generation { apply(result) }
        sampling = false
        let next = refreshRequested ? 1 : nextInterval()
        refreshRequested = false
        schedule(after: next)
    }
    private func apply(_ result: MonitoringResult) {
        thermal = result.thermal
        loadAverage = result.loadAverage
        lastSampleDate = result.date
        lastSampleCostMilliseconds = result.elapsedMilliseconds
        totalProcessCount = result.totalProcessCount
        readableProcessCount = result.readableProcessCount
        ownCPUPercent = result.ownCPU
        ownMemoryBytes = result.ownMemory
        if let cpu = result.cpu {
            hostCPUPercent = min(max(cpu, 0), 100)
            processes = result.processes
            pruneAutomaticPermissions()
            if !policyCPUObservations.isEmpty {
                let active = actions.activeIdentities
                for key in Array(policyCPUObservations.keys) {
                    guard var value = policyCPUObservations[key] else { continue }
                    guard value.appliedIdentities.isSubset(of: active) else {
                        policyCPUObservations.removeValue(forKey: key)
                        markPolicyFeedbackInterrupted(
                            groupKey: key,
                            explanation: "后台调度已结束；完整观察窗口未完成，不能判断 CPU 变化。")
                        continue
                    }
                    guard let current = processes.first(where: { value.matches($0) }) else {
                        policyCPUObservations.removeValue(forKey: key)
                        markPolicyFeedbackInterrupted(
                            groupKey: key,
                            explanation: "目标暂时不可读，或身份/成员发生变化；完整观察窗口未完成，不能判断 CPU 变化。")
                        continue
                    }
                    let wasComplete = value.isComplete
                    if let previousResultDate {
                        value.append(current, from: previousResultDate, to: result.date,
                                     temperatureCelsius: temperature?.celsius,
                                     temperatureDate: temperature?.date)
                    }
                    policyCPUObservations[key] = value
                    if let feedback = lastPolicyFeedback,
                       feedback.groupKey == key, feedback.pending {
                        lastPolicyFeedback = PolicyFeedback(
                            date: result.date,
                            displayName: current.displayName,
                            groupKey: key,
                            effectSummary: feedback.effectSummary,
                            summary: value.summary,
                            explanation: value.explanation,
                            pending: !value.isComplete,
                            remainsHigh: value.remainsHigh,
                            cancelled: false,
                            interrupted: false)
                    }
                    if !wasComplete && value.isComplete {
                        lastPolicyFeedback = PolicyFeedback(
                            date: result.date,
                            displayName: current.displayName,
                            groupKey: key,
                            effectSummary: lastPolicyFeedback?.effectSummary,
                            summary: value.summary,
                            explanation: value.explanation,
                            pending: false,
                            remainsHigh: value.remainsHigh,
                            cancelled: false,
                            interrupted: false)
                    }
                }
            }
            if isScanning, let previousResultDate {
                scanAccumulator.append(result, seconds: result.date.timeIntervalSince(previousResultDate))
            }
            let point = HostPoint(date: result.date, cpuPercent: hostCPUPercent, thermal: thermal,
                                  temperature: temperature?.celsius, topApplication: topProcesses.first?.displayName)
            if let previous = lastExposurePoint,
               let previousTemperature = previous.temperature,
               let currentTemperature = point.temperature {
                let gap = point.date.timeIntervalSince(previous.date)
                if gap > 0, gap <= ThermalExposureLedger.maximumContinuousGap {
                    ThermalExposureLedger.appendInterval(
                        from: previous.date, to: point.date,
                        lowerBoundTemperature: min(previousTemperature, currentTemperature),
                        peakTemperature: max(previousTemperature, currentTemperature),
                        hostCPUPercent: max(previous.cpuPercent, point.cpuPercent),
                        into: &thermalExposure)
                }
            }
            // Keep a point with a missing temperature as a hard boundary; the
            // next valid reading must not bridge an unavailable sensor gap.
            lastExposurePoint = point
            TrendBuffer.append(point, to: &history)
            evaluateAutomaticProtection()
        } else {
            // Host/process deltas share one validity interval. If the worker
            // rejects a frame (sleep, wall-clock jump, missing host ticks, or
            // a stalled sample), do not let the next valid frame inherit the
            // old 5/20-minute automatic-protection claim.
            revokeAutomaticProtection()
            invalidatePolicyFeedback(at: result.date)
            lastExposurePoint = nil
            autoProtectionStatus = "采样基线重建中：本轮连续证据已清零，取消和保护选择仍保留。"
        }
        previousResultDate = result.date
        maintainPolicies()
        refreshTemperatureIfNeeded()
        if isScanning {
            let elapsed = ProcessInfo.processInfo.systemUptime - scanStartUptime
            scanProgress = min(elapsed / scanDuration, 0.97)
            if elapsed >= scanDuration { finishDiagnostic(elapsed: elapsed) }
            else { statusMessage = "连续采样中：剩余约 \(max(0, Int(ceil(scanDuration - elapsed)))) 秒" }
        } else if Date() >= transientUntil {
            statusMessage = ambientStatus()
        }
        if Date().timeIntervalSince(lastPersist) >= 60 { persistNow() }
    }
    private func finishDiagnostic(elapsed: TimeInterval) {
        guard deepScanTask == nil else { return }
        statusMessage = "正在补充一次系统深扫…"
        let context = makeAnalysisContext()
        let limited = actions.activeIdentities
        deepScanTask = Task {
            let deep = await worker.deepScan(context: context, limited: limited)
            guard !Task.isCancelled else { return }
            let observed = scanAccumulator.contributors
            let merged = ReportMerger.merge(observed: observed, deep: deep.processes)
            let coverage = "连续观察 \(Int(elapsed)) 秒；CPU 可读 \(readableProcessCount)/\(totalProcessCount) 个进程。"
                + (deep.succeeded ? "系统补充项为末尾约 1 秒快照，不与观察期均值混用。" : "系统深扫未成功，报告仅含已观察到的进程。")
            let finished = ReportBuilder.make(duration: elapsed, thermal: thermal,
                hostCPU: scanAccumulator.duration > 0 ? scanAccumulator.meanHostCPU : hostCPUPercent,
                processes: merged, temperatureCelsius: temperature?.celsius, coverageNote: coverage)
            report = finished
            reportHistory.append(finished)
            reportHistory = Array(reportHistory.suffix(12))
            isScanning = false
            scanStartedAt = nil
            scanProgress = 1
            deepScanTask = nil
            recordEvent(finished.summary)
            schedule(after: nextInterval())
        }
    }
    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        guard ready, !sleeping else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.sampleNow() }
        }
        timer?.tolerance = min(interval * 0.2, 3)
    }
    private func nextInterval() -> TimeInterval {
        return SamplingCadencePolicy.interval(mode: samplingMode,
            automaticMode: autoProtectionSettings.mode,
            thermal: thermal, active: NSApp.isActive,
            scanning: isScanning, countdown: autoProtectionCountdownActive)
    }
    private func makeAnalysisContext() -> AnalysisContext {
        AnalysisContextCapture.capture(protectedKeys: Set(protectedApps.keys))
    }
    private func refreshTemperatureIfNeeded() {
        // Explicit automatic protection gets a fresher thermal evidence chain
        // while remaining off the hot path for the default observe mode.
        let interval: Double = isScanning ? 5
            : (autoProtectionSettings.mode == .enforce ? 20
               : (thermal >= .fair ? 20 : (NSApp.isActive ? 20 : 60)))
        let now = Date()
        // A wall-clock rollback otherwise leaves a negative elapsed time and
        // suppresses fresh hardware reads until the clock catches up.
        if now < lastTemperatureRefresh { lastTemperatureRefresh = .distantPast }
        guard !temperatureRefreshInFlight, now.timeIntervalSince(lastTemperatureRefresh) >= interval else { return }
        temperatureRefreshInFlight = true
        lastTemperatureRefresh = now
        let epoch = generation
        Task {
            let reading = await TemperatureProvider.read()
            acceptTemperatureReading(reading, generation: epoch)
            temperatureRefreshInFlight = false
        }
    }

    /// Complete sensor faults on the main actor immediately, including the
    /// queued-action token and visible warning. Waiting for the next process
    /// frame would leave a warning live after its prerequisite disappeared.
    private func acceptTemperatureReading(_ reading: TemperatureReading?, generation epoch: Int) {
        guard epoch == generation else { return }
        guard let reading, reading.isUsable(at: automaticClock.now()) else {
            temperature = nil
            revokeAutomaticProtection()
            autoProtectionStatus = "温度参考不可用或已过期：自动保护已暂停，恢复后重新积累证据。"
            return
        }
        if let previous = temperature, reading.date < previous.date {
            revokeAutomaticProtection()
            autoProtectionStatus = "温度时间戳回退：自动保护重新积累连续证据。"
        }
        temperature = reading
    }
    private func thermalDidChange() {
        thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        guard thermal >= .serious, Date().timeIntervalSince(lastAutoScan) >= 900 else { return }
        lastAutoScan = Date()
        if notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "温衡：系统热压力" + thermal.title
            content.body = "已提高低扰动监测频率；不会自动启动深度排查。需要时请手动点击一键排查。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heatguard.thermal", content: content, trigger: nil))
        }
        // Do not start a 30-second deep scan from the thermal callback. A
        // diagnostic enumerates and enriches many processes exactly while
        // the machine is already under heat pressure, which can amplify the
        // problem and make the monitor part of the incident. The normal
        // serious-thermal cadence remains active; a user can still request a
        // bounded scan explicitly from the dashboard.
        if !isScanning { schedule(after: nextInterval()) }
    }
    private func willSleep() {
        setSessionInactive(.systemSleep, inactive: true)
        persistNow()
    }
    private func didWake() {
        setSessionInactive(.systemSleep, inactive: false)
    }

    private func screenDidUnlock() {
        // Cold start behind an already-locked but lit screen has no recorded
        // lock reason to transition out of. Always reset advice-mode evidence
        // before confirming, even if setSessionInactive will be a no-op.
        revokeAutomaticProtection()
        automaticSessionConfirmed = true
        setSessionInactive(.screenLocked, inactive: false)
    }

    /// Locking the screen, switching users, or sleeping the display makes a
    /// 30-second danger window invisible. Pause sampling and invalidate the
    /// evidence/token until the interactive session is active again.
    private func setSessionInactive(_ reason: ProtectionSessionGate.Reason, inactive: Bool) {
        if inactive, reason != .displaySleep { automaticSessionConfirmed = false }
        let wasPaused = sessionGate.isPaused
        sessionGate.set(reason, inactive: inactive)
        guard wasPaused != sessionGate.isPaused else { return }
        if sessionGate.isPaused { workspaceBecameInactive() }
        else { workspaceBecameActive() }
    }

    private func workspaceBecameInactive() {
        generation += 1
        dismissAutomaticPolicyConfirmation()
        cancelAutomaticPermission()
        timer?.invalidate()
        if isScanning { cancelDiagnostic() }
        temperature = nil
        lastExposurePoint = nil
        invalidatePolicyFeedback(at: Date())
        revokeAutomaticProtection()
        autoProtectionStatus = "屏幕或会话不可交互：自动保护已暂停，恢复后重新积累证据。"
    }

    private func invalidatePolicyFeedback(at date: Date) {
        for key in Array(policyCPUObservations.keys) {
            policyCPUObservations[key]?.invalidate(at: date)
        }
        // Keep the overview card honest when a sleep, session pause or
        // invalid sample interrupts the observation. The operation may still
        // be active and can resume later, so retain a pending card but rebuild
        // its text from the reset observation instead of leaving stale CPU
        // averages or a misleading old progress state on screen.
        if let feedback = lastPolicyFeedback,
           feedback.pending,
           let observation = policyCPUObservations[feedback.groupKey] {
            lastPolicyFeedback = PolicyFeedback(
                date: date,
                displayName: feedback.displayName,
                groupKey: feedback.groupKey,
                effectSummary: feedback.effectSummary,
                summary: observation.summary,
                explanation: "观察窗口已暂停或采样失效；已从 0 秒重新开始，恢复后不会补算中断时间。",
                pending: true,
                remainsHigh: false,
                cancelled: false,
                interrupted: false)
        }
    }

    /// A user can restore a policy before the one-minute feedback window
    /// completes. Close that card explicitly instead of leaving it saying
    /// "observing" forever after the observation is discarded on the next
    /// sample. Completed observations remain as real evidence and are not
    /// relabeled as cancelled.
    private func markPolicyFeedbackCancelled(groupKey: String) {
        guard let feedback = lastPolicyFeedback,
              feedback.groupKey == groupKey,
              feedback.pending else { return }
        lastPolicyFeedback = PolicyFeedback(
            date: Date(),
            displayName: feedback.displayName,
            groupKey: feedback.groupKey,
            effectSummary: feedback.effectSummary,
            summary: feedback.summary,
            explanation: "已撤销；完整观察窗口未完成，不能判断 CPU 变化。",
            pending: false,
            remainsHigh: false,
            cancelled: true,
            interrupted: false)
    }

    private func markPolicyFeedbackInterrupted(groupKey: String, explanation: String) {
        guard let feedback = lastPolicyFeedback,
              feedback.groupKey == groupKey,
              feedback.pending else { return }
        lastPolicyFeedback = PolicyFeedback(
            date: Date(),
            displayName: feedback.displayName,
            groupKey: feedback.groupKey,
            effectSummary: feedback.effectSummary,
            summary: feedback.summary,
            explanation: explanation,
            pending: false,
            remainsHigh: false,
            cancelled: false,
            interrupted: true)
    }

    private func workspaceBecameActive() {
        generation += 1
        fullReset = true
        previousResultDate = nil
        lastTemperatureRefresh = .distantPast
        revokeAutomaticProtection()
        maintainPolicies()
        sampleNowFromUI()
    }

    private func automaticSessionIsUsable() -> Bool {
        guard automaticSessionConfirmed, !sleeping else { return false }
        guard sessionSnapshot().isInteractive else {
            // A missed resign/sleep notification is still detected by the
            // snapshot. Do not silently resume later with advice accumulated
            // while nobody could see or cancel a warning.
            automaticSessionConfirmed = false
            revokeAutomaticProtection()
            return false
        }
        return true
    }

    @discardableResult
    private func evaluateAutomaticProtection() -> Task<Void, Never>? {
        let sessionBlocked = autoProtectionSettings.mode == .enforce
            && !automaticSessionIsUsable()
        var effectiveSettings = autoProtectionSettings
        if sessionBlocked {
            // Continue the five-minute anomaly explanation while destructive
            // automation is paused. Confirmation below resets all evidence,
            // so observation time cannot trigger an immediate kill on resume.
            effectiveSettings.mode = .advise
            if autoProtectionCountdownActive || autoCountdownDeadlineUptime != nil {
                revokeAutomaticProtection()
            }
        }
        let decision = automaticProtection.observe(now: automaticClock.now(), temperature: temperature?.celsius,
            temperatureDate: temperature?.date, processes: processes,
            settings: effectiveSettings, isScanning: isScanning,
            authorizedTargets: Set(automaticTerminationGrants.keys))
        switch decision.kind {
        case .none:
            countdownNotice.dismiss()
            if !isActionBusy { invalidateAutomaticAction() }
            autoProtectionCountdownActive = false
            autoCountdownKey = nil
            autoProtectionStatus = autoProtectionSettings.mode == .observe
                ? "自动保护：仅观察" : decision.reason
        case .anomaly:
            countdownNotice.dismiss()
            if !isActionBusy { invalidateAutomaticAction() }
            autoProtectionCountdownActive = false
            autoCountdownKey = nil
            autoProtectionStatus = decision.process.map { "异常候选：\($0.displayName) · \(decision.reason)" } ?? decision.reason
            if autoProtectionSettings.mode != .observe, Date().timeIntervalSince(lastAutoNotice) >= 900 {
                lastAutoNotice = Date()
                if notificationsEnabled {
                    let content = UNMutableNotificationContent()
                    content.title = "温衡：持续高温异常候选"
                    content.body = autoProtectionStatus
                    UNUserNotificationCenter.current().add(UNNotificationRequest(
                        identifier: "heatguard.auto-anomaly", content: content, trigger: nil))
                }
                recordEvent(autoProtectionStatus)
            }
        case .countdown:
            autoProtectionCountdownActive = true
            autoProtectionStatus = decision.process.map { "自动保护：\($0.displayName) · \(decision.reason)" } ?? decision.reason
            if let process = decision.process, autoCountdownKey != process.groupKey {
                autoCountdownKey = process.groupKey
                autoActionEpoch &+= 1
                autoCountdownDeadlineUptime = automaticClock.uptime() + 30
                announceAutomaticCountdown(for: process)
            }
        case .blocked:
            countdownNotice.dismiss()
            if !isActionBusy { invalidateAutomaticAction() }
            autoProtectionCountdownActive = false
            autoCountdownKey = nil
            autoProtectionStatus = decision.reason
        case .enforce:
            countdownNotice.dismiss()
            autoProtectionCountdownActive = false
            autoCountdownKey = nil
            let immediate = autoProtectionSettings.automaticTerminationTiming.isImmediate
            if !immediate {
                guard let deadline = autoCountdownDeadlineUptime,
                      automaticClock.uptime() >= deadline else {
                    if let process = decision.process { automaticProtection.abortEnforcement(for: process) }
                    invalidateAutomaticAction()
                    autoProtectionStatus = "自动保护已取消：单调倒计时尚未完成。"
                    return nil
                }
                autoCountdownDeadlineUptime = nil
            }
            let actionEpoch = autoActionEpoch
            guard let process = decision.process, !isScanning else { return nil }
            guard !isActionBusy, !policyMaintenance else {
                automaticProtection.abortEnforcement(for: process)
                autoProtectionStatus = "自动保护已延后：正在完成另一项操作。"
                return nil
            }
            if immediate {
                // A timing change normally revokes this already, but clear a
                // stale deadline defensively before the no-window path.
                autoCountdownDeadlineUptime = nil
                announceAutomaticImmediate(for: process)
            }
            autoProtectionStatus = "正在自动保护：\(process.displayName)"
            return runAction { await self.executeAutomaticProtection(process, epoch: actionEpoch) }
        }
        if sessionBlocked {
            autoProtectionStatus += " 自动结束已暂停：请在安全设置确认本次会话；普通监测和异常判断继续。"
        }
        return nil
    }

    private func invalidateAutomaticAction() {
        autoActionEpoch &+= 1
        autoCountdownDeadlineUptime = nil
    }

    /// Evidence, execution authorization and warning UI form one transaction.
    /// Invalidating only the engine leaves an already queued action authorized
    /// and can leave a panel claiming that a cancelled countdown is still live.
    private func revokeAutomaticProtection() {
        automaticProtection.invalidateEvidence()
        invalidateAutomaticAction()
        countdownNotice.dismiss()
        autoProtectionCountdownActive = false
        autoCountdownKey = nil
    }

    /// The decision was produced by the previous sample, while the 30-second
    /// countdown gives the process and user time to change state. Before an
    /// automatic kill, require a fresh matching sample with the same complete
    /// identity set and still-high CPU. This prevents a stale `.enforce`
    /// decision from ending a task that cooled down during the countdown.
    private func executeAutomaticProtection(_ process: AppProcess, epoch: UInt64) async -> ActionResult {
        let now = automaticClock.now()
        guard ready, automaticSessionIsUsable(),
              epoch == autoActionEpoch,
              autoProtectionSettings.mode == .enforce, !isScanning,
              let lastSampleDate,
              now.timeIntervalSince(lastSampleDate) >= 0,
              now.timeIntervalSince(lastSampleDate) <= 45,
              let reading = temperature,
              reading.isUsable(at: now, maximumAge: 45),
              reading.celsius >= autoProtectionSettings.enforceTemperatureCelsius,
              let latest = processes.first(where: { $0.groupKey == process.groupKey }),
              latest.id == process.id,
              latest.executablePath != nil, latest.executablePath == process.executablePath,
              Set(latest.memberIdentities) == Set(process.memberIdentities),
              latest.isBackground, !latest.isForeground, !latest.isProtected,
              !isUserProtected(latest),
              latest.automaticContextBlockReason == nil,
              !latest.isSoftLimited,
              !LocalKnowledgeBase.isAutomaticProtectionExcluded(
                  name: latest.name, path: latest.path, bundleIdentifier: latest.bundleIdentifier),
              !LocalKnowledgeBase.isAutomaticProtectionExcluded(
                name: latest.name, path: latest.executablePath ?? "", bundleIdentifier: latest.bundleIdentifier),
              latest.cpuPercent >= autoProtectionSettings.minimumCPUPercent,
              latest.risk >= .elevated else {
            automaticProtection.abortEnforcement(for: process)
            return .failure("自动保护已取消：倒计时后目标状态已变化或最新证据已过期。")
        }
        let authorizedTargets = Set(automaticTerminationGrants.keys)
        // Re-read the complete evidence ledger at the action boundary.  A
        // per-run grant is identity permission, not proof that the task is
        // idle; an active disk/wakeup workload must never be killed merely
        // because it stayed above the CPU threshold.
        guard let currentEvidence = automaticProtection.evidence(
                  for: latest, now: now, settings: autoProtectionSettings,
                  authorizedTargets: authorizedTargets),
              currentEvidence.blockedReason == nil,
              currentEvidence.highCPUDuration >= autoProtectionSettings.enforceDuration,
              currentEvidence.idleDuration >= autoProtectionSettings.enforceDuration,
              currentEvidence.enforceTemperatureDuration >= autoProtectionSettings.enforceDuration,
              ActivitySignature.lowIOHighCPU(cpuPercent: latest.cpuPercent,
                  diskBytesPerSecond: latest.diskBytesPerSecond,
                  wakeupsPerSecond: latest.wakeupsPerSecond,
                  diskAvailable: latest.diskAvailable,
                  wakeupsAvailable: latest.wakeupsAvailable) else {
            automaticProtection.abortEnforcement(for: process)
            return .failure("自动保护已取消：最新证据不再满足连续低 I/O 空转、温度或 CPU 时长门槛。")
        }
        let explicitAuthority = automaticProtection.hasAutomaticAuthority(
            for: latest, authorizedTargets: authorizedTargets)
        let clearIdleTargetAllowed = latest.bundleIdentifier != nil
            || (autoProtectionSettings.automaticTerminationScope.allowsEphemeralCLI
                && LocalKnowledgeBase.isEphemeralCommandLineTarget(
                    name: latest.name, path: latest.path,
                    bundleIdentifier: latest.bundleIdentifier,
                    executablePath: latest.executablePath))
        let clearIdleAuthority = autoProtectionSettings.automaticTerminationScope.allowsClearIdle
            && clearIdleTargetAllowed
            && AutomaticTerminationGrant(process: latest) != nil
            && ActivitySignature.lowIOHighCPU(cpuPercent: latest.cpuPercent,
                diskBytesPerSecond: latest.diskBytesPerSecond,
                wakeupsPerSecond: latest.wakeupsPerSecond,
                diskAvailable: latest.diskAvailable,
                wakeupsAvailable: latest.wakeupsAvailable)
        guard explicitAuthority || clearIdleAuthority else {
            automaticProtection.abortEnforcement(for: process)
            let reason = autoProtectionSettings.automaticTerminationScope.allowsClearIdle
                ? "自动保护已取消：最新读数不再满足低 I/O 空转或明确授权门槛。"
                : "自动保护已取消：倒计时后目标状态已变化或最新证据已过期。"
            return .failure(reason)
        }
        if autoProtectionSettings.automaticTerminationTiming.isImmediate {
            guard clearIdleAuthority else {
                automaticProtection.abortEnforcement(for: process)
                return .failure("直接自动保护已取消：最新读数不再满足连续低 I/O 空转门槛。")
            }
        }
        let result = await actions.forceTerminate(latest, automatic: true)
        if case .failure = result {
            automaticProtection.abortEnforcement(for: latest)
        }
        return result
    }

    func cancelAutomaticProtection() {
        countdownNotice.dismiss()
        invalidateAutomaticAction()
        automaticProtection.cancelCountdown()
        autoProtectionCountdownActive = false
        autoCountdownKey = nil
        autoProtectionStatus = "你已取消本次自动保护；温度回落前不会重复倒计时。"
        recordEvent(autoProtectionStatus)
    }

    /// Automatic SIGKILL is deliberately preceded by an attention signal even
    /// when the user has disabled ordinary notifications. The menu-bar state
    /// remains the source of truth; this extra nudge makes a 30-second danger
    /// window discoverable instead of silently ending background work.
    private func announceAutomaticCountdown(for process: AppProcess) {
        countdownNotice.show(process: process,
            deadlineUptime: autoCountdownDeadlineUptime ?? automaticClock.uptime(),
            onCancel: { [weak self] in self?.cancelAutomaticProtection() },
            onOpen: { [weak self] in self?.openDashboard() })
        if notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "温衡：自动保护倒计时"
            content.body = "\(process.displayName) 将在约 30 秒后自动结束；打开温衡可取消。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "heatguard.auto-countdown", content: content, trigger: nil))
        }
        recordEvent("自动保护倒计时开始：\(process.displayName)，30 秒内可取消。")
    }

    /// Immediate mode intentionally has no cancellable danger panel. Make the
    /// pending action visible, but do not claim that a signal was sent before
    /// the final identity/foreground gate and the native termination result
    /// return. The action result is the only source of truth for completion.
    private func announceAutomaticImmediate(for process: AppProcess) {
        if notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "温衡：直接自动保护最终核验"
            content.body = "\(process.displayName) 已达到策略门槛，正在核对最新身份、路径和前台状态。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "heatguard.auto-immediate", content: content, trigger: nil))
        }
        recordEvent("直接自动保护进入最终核验：\(process.displayName)，尚未发送结束请求。")
    }

    /// Bring the dashboard forward only after an explicit click in the danger
    /// notice. The notice itself remains non-activating so normal work keeps
    /// keyboard focus during the cancellation window.
    func openDashboard() {
        countdownNotice.dismiss()
        if let dashboardOpener {
            dashboardOpener()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue != "heatguard.countdown"
                && !($0 is NSPanel) && $0.canBecomeKey && $0.contentView != nil
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            showStatus("主界面尚未创建；请从菜单栏再次点击“打开温衡”。")
        }
    }

    func installDashboardOpener(_ opener: @escaping @MainActor () -> Void) {
        dashboardOpener = opener
    }

    private func ambientStatus() -> String {
        if thermal >= .serious { return "系统热压力较高；请查看排查报告并核对正在运行的任务。" }
        if let first = topProcesses.first, first.cpuPercent >= 80 {
            return "主要 CPU 贡献者：" + first.displayName + "（" + first.cpuPercent.percentText + "）"
        }
        return "离线监控中。高 CPU 不等于空转；持续后台证据会在进程卡片中标出。"
    }
    private func addObserver(_ name: Notification.Name, center: NotificationCenter = .default,
                             handler: @Sendable @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }
    private func showStatus(_ message: String) {
        statusMessage = message
        transientUntil = Date().addingTimeInterval(15)
    }
    private func recordEvent(_ message: String) {
        events.append(ActivityEvent(date: Date(), message: message))
        events = Array(events.suffix(60))
        showStatus(message)
        persistNow()
    }
    private func persistNow() {
        guard ready else { return }
        lastPersist = Date()
        let value = SavedHistory(points: history, reports: reportHistory, events: events,
                                 thermalExposure: thermalExposure)
        Task {
            do { try await store.save(value) }
            catch { showStatus("历史保存失败：" + error.localizedDescription) }
        }
    }
    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Exercises the real invalid-frame handler without running a sampler, opening
/// a warning, persisting preferences, or granting permission to send a signal.
/// Kept in this file so production state does not need public mutation hooks.
extension MonitorModel {
    /// Reproduce a confirmation snapshot becoming unsafe before its queued
    /// action starts. The caller owns the one native child; all new protection
    /// and age/identity facts are synthetic, preferences remain in memory.
    static func manualConfirmationRegressions(process: AppProcess, dataDirectory: URL) async
        -> [(name: String, passed: Bool)] {
        var results: [(String, Bool)] = []
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        let protected = AppProcess(id: process.id, memberIdentities: process.memberIdentities,
            pid: process.pid, parentPID: process.parentPID, uid: process.uid,
            name: process.name, displayName: process.displayName, bundleIdentifier: process.bundleIdentifier,
            path: process.path, cpuPercent: process.cpuPercent, wakeupsPerSecond: process.wakeupsPerSecond,
            diskBytesPerSecond: process.diskBytesPerSecond, residentBytes: process.residentBytes,
            isForeground: false, isBackground: true, isSystem: false, isProtected: true,
            protectionReason: "上级任务已退出，继承保护仍有效", isSoftLimited: false, risk: .watch,
            confidence: process.confidence, evidence: [], recommendation: "test only",
            executablePath: process.executablePath)
        for action in ["force", "terminate", "soften"] {
            for fault in ["继承保护更新", "目标缺帧", "采样过期", "执行路径变化"] {
                let model = MonitorModel(autoStart: false,
                    dataDirectory: dataDirectory.appendingPathComponent(action + "-" + fault),
                    sessionSnapshot: { interactive }, preferences: InMemoryPreferences())
                model.ready = true
                model.sampling = true
                model.temperatureRefreshInFlight = true
                model.processes = [process]
                model.lastSampleDate = Date()
                guard model.currentManualActionTarget(process) != nil else {
                    results.append(("手动确认阳性上下文 " + action, false))
                    await model.prepareForTermination()
                    return results
                }
                switch action {
                case "force": model.askToForceTerminate(process); model.confirmForceTermination()
                case "terminate": model.askToTerminate(process); model.confirmTermination()
                default: model.askToSoften(process); model.confirmSoften()
                }
                let queued = model.isActionBusy
                // No await before this mutation: production runAction has
                // captured the old sheet, but its Task has not started yet.
                switch fault {
                case "继承保护更新": model.processes = [protected]
                case "目标缺帧": model.processes = []
                case "采样过期": model.lastSampleDate = Date().addingTimeInterval(-91)
                default:
                    var replacement = process
                    replacement.executablePath = "/private/tmp/changed-executable"
                    model.processes = [replacement]
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while model.isActionBusy && ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                let alive = NativeSampler.process(pid: process.pid)?.identity == process.id
                results.append(("手动确认排队复核：" + action + " / " + fault,
                    queued && !model.isActionBusy && model.events.last?.message.contains("已取消") == true
                        && model.activePolicies.isEmpty && alive))
                await model.prepareForTermination()
                if !alive { return results }
            }
        }
        return results
    }

    /// Positive counterpart to the stale-confirmation matrix; dispatches only
    /// the integration suite's dedicated native child, never a sampled task.
    static func manualForceExecutionRegression(process: AppProcess, dataDirectory: URL) async -> Bool {
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true) },
            preferences: InMemoryPreferences())
        model.ready = true
        model.sampling = true
        model.temperatureRefreshInFlight = true
        model.processes = [process]
        model.lastSampleDate = Date()
        model.askToForceTerminate(process)
        let sheetOpened = model.showForceTerminationConfirmation && model.pendingForceTermination?.id == process.id
        model.confirmForceTermination()
        let queued = model.isActionBusy
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while model.isActionBusy && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let passed = sheetOpened && queued && !model.isActionBusy
            && !model.showForceTerminationConfirmation && model.pendingForceTermination == nil
            && model.events.last?.message.hasPrefix("已强制结束") == true
            && NativeSampler.process(pid: process.pid) == nil
        await model.prepareForTermination()
        return passed
    }

    /// Drives the actual coordinator, warning, monotonic gate, queued Task and
    /// native ActionExecutor in order. Only clocks, readings/session and notice
    /// rendering are synthetic. The caller owns the sole real signal target.
    static func automaticLifecycleRegressions(process: AppProcess, dataDirectory: URL,
        scope: AutomaticTerminationScope) async -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        let timeline = AutomaticProtectionTestClock()
        let notice = RecordingAutomaticCountdown()
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .enforce, automaticTerminationScope: scope),
            preferences: InMemoryPreferences(), automaticClock: timeline.clock, countdownNotice: notice)
        defer { model.ready = false; model.timer?.invalidate(); notice.dismiss() }
        // Input frames below are owned by the fixture, not a live sampler.
        model.temperatureRefreshInFlight = true
        model.sampling = true
        model.processes = [process]
        model.lastSampleDate = timeline.date
        model.confirmAutomaticProtectionForSession()
        if scope == .explicitGrant {
            model.askToAllowAutomaticTermination(process)
            model.confirmAutomaticPermission()
        }
        let label = scope == .explicitGrant ? "逐项授权" : "空转范围"
        var results: [(name: String, passed: Bool)] = []
        func check(_ name: String, _ passed: Bool) { results.append((label + "：" + name, passed)) }
        let authorized = scope == .explicitGrant
            ? model.hasAutomaticPermission(process) : model.automaticTerminationGrants.isEmpty
        guard authorized, model.automaticSessionConfirmed else {
            check("本次会话和授权范围初始化", false)
            return results
        }
        func reading(_ value: Double = 75, age: TimeInterval = 0, sensors: Int = 1) -> TemperatureReading {
            TemperatureReading(celsius: value, sensorCount: sensors, source: .appleSMC,
                date: timeline.date.addingTimeInterval(-age))
        }
        @discardableResult
        func step(_ seconds: TimeInterval, uptimeDelta: TimeInterval? = nil,
                  celsius: Double = 75) -> Task<Void, Never>? {
            timeline.advance(seconds, uptimeDelta: uptimeDelta)
            model.lastSampleDate = timeline.date
            model.acceptTemperatureReading(reading(celsius), generation: model.generation)
            return model.evaluateAutomaticProtection()
        }
        func beginCountdown() -> Bool {
            model.ready = false
            model.revokeAutomaticProtection()
            let originalNotices = notice.presentations
            step(0)
            var noEarlyAction = !model.autoProtectionCountdownActive && !model.isActionBusy
            for _ in 1..<40 {
                noEarlyAction = (step(30) == nil) && noEarlyAction
                    && !model.autoProtectionCountdownActive && !model.isActionBusy
            }
            step(30)
            return noEarlyAction && model.autoProtectionCountdownActive && notice.isPresented
                && notice.presentations == originalNotices + 1
                && notice.deadlineUptime == timeline.uptime + 30
        }

        // Verify the distinct five-minute advisory threshold on the same path.
        step(0, celsius: 66)
        for _ in 1...10 { step(30, celsius: 66) }
        check("65°C 五分钟形成异常提示但不自动结束",
            model.autoProtectionStatus.contains("异常候选") && !notice.isPresented && !model.isActionBusy)

        for fault in 0..<7 {
            guard beginCountdown() else { check("故障测试先经过完整二十分钟倒计时", false); return results }
            let epoch = model.autoActionEpoch
            let invalid: TemperatureReading?
            switch fault {
            case 0: invalid = nil
            case 1: invalid = reading(.nan)
            case 2: invalid = reading(150)
            case 3: invalid = reading(-1)
            case 4: invalid = reading(age: 91)
            case 5: invalid = reading(age: -1)
            default: invalid = reading(sensors: 0)
            }
            model.acceptTemperatureReading(invalid, generation: model.generation)
            let revokedImmediately = model.temperature == nil && model.autoActionEpoch != epoch
                && !model.autoProtectionCountdownActive && !notice.isPresented
                && model.autoCountdownDeadlineUptime == nil
            step(30)
            let evidence = model.automaticEvidence(for: process)
            check("温度故障 \(fault + 1) 立即撤销警示和令牌且恢复从零计时",
                revokedImmediately && !model.autoProtectionCountdownActive
                    && evidence?.highCPUDuration == 0 && evidence?.enforceTemperatureDuration == 0
                    && NativeSampler.process(pid: process.pid)?.identity == process.id)
        }

        guard beginCountdown() else { check("过期回调测试倒计时前提", false); return results }
        let epochBeforeOldReply = model.autoActionEpoch
        model.acceptTemperatureReading(nil, generation: model.generation - 1)
        check("旧生命周期的迟到温度回调不覆盖新证据",
            model.autoActionEpoch == epochBeforeOldReply && notice.isPresented && model.temperature != nil)

        model.ready = true
        let tooEarly = step(30, uptimeDelta: 1)
        check("墙上时间走满但实际倒计时未到不执行也不留下假冷却期",
            tooEarly == nil && !model.isActionBusy && !notice.isPresented
                && model.autoProtectionStatus.contains("单调倒计时尚未完成")
                && NativeSampler.process(pid: process.pid)?.identity == process.id && beginCountdown())

        // Queue through the real .enforce branch, then revoke and recover the
        // sensor before yielding. The queued closure must reject its old token
        // even though the latest reading has already become valid again.
        model.ready = true
        guard let queued = step(30) else { check("生产协调器排队自动动作", false); return results }
        let queuedEpoch = model.autoActionEpoch
        model.acceptTemperatureReading(nil, generation: model.generation)
        model.acceptTemperatureReading(reading(), generation: model.generation)
        await queued.value
        check("温度故障后即使立刻恢复仍撤销已排队的真实动作",
            model.autoActionEpoch != queuedEpoch && !model.isActionBusy && !notice.isPresented
                && model.events.last?.message.contains("自动保护已取消") == true
                && NativeSampler.process(pid: process.pid)?.identity == process.id)

        guard beginCountdown() else { check("取消按钮测试倒计时前提", false); return results }
        notice.cancelFromNotice()
        step(30)
        check("警示取消回调阻止本次事件再次执行",
            !model.autoProtectionCountdownActive && !model.isActionBusy && !notice.isPresented
                && NativeSampler.process(pid: process.pid)?.identity == process.id)
        // A genuine cooldown below the threshold ends that cancelled incident.
        step(30, celsius: 60)

        guard beginCountdown() else { check("完整链路最后一次二十分钟证据", false); return results }
        let noticesBeforeDeadline = notice.presentations
        step(29)
        check("第 29 秒仍给用户取消机会且不重复弹警示",
            notice.isPresented && model.autoProtectionCountdownActive && !model.isActionBusy
                && notice.presentations == noticesBeforeDeadline
                && NativeSampler.process(pid: process.pid)?.identity == process.id)
        model.ready = true
        guard let completed = step(1) else { check("第 30 秒从协调器进入实际执行", false); return results }
        await completed.value
        check("生产协调器经过倒计时和排队后实际结束私有目标并核验终态",
            !model.isActionBusy && !notice.isPresented && !model.autoProtectionCountdownActive
                && model.events.last?.message.hasPrefix("已强制结束") == true
                && NativeSampler.process(pid: process.pid) == nil)
        check("动作后没有扩大逐项授权范围",
            scope == .explicitGrant ? model.automaticTerminationGrants.count == 1
                : model.automaticTerminationGrants.isEmpty)
        await model.prepareForTermination()
        return results
    }

    /// Positive integration counterpart for the high-risk timing choice. It
    /// uses the same production coordinator and native force-termination path
    /// as the cancellable lifecycle above, but asserts that no countdown panel
    /// or 30-second deadline is created when the user has explicitly enabled
    /// immediate clear-idle automation.
    static func automaticImmediateExecutionRegression(process: AppProcess,
        dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        let timeline = AutomaticProtectionTestClock()
        let notice = RecordingAutomaticCountdown()
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .enforce,
                automaticTerminationScope: .clearIdle, automaticTerminationTiming: .immediate),
            preferences: InMemoryPreferences(), automaticClock: timeline.clock, countdownNotice: notice)
        defer { model.ready = false; model.timer?.invalidate(); notice.dismiss() }
        model.temperatureRefreshInFlight = true
        model.sampling = true
        model.processes = [process]
        model.lastSampleDate = timeline.date
        model.confirmAutomaticProtectionForSession()
        var results: [(name: String, passed: Bool)] = []
        func check(_ name: String, _ passed: Bool) { results.append(("直接自动结束：" + name, passed)) }
        guard model.automaticSessionConfirmed,
              model.autoProtectionSettings.automaticTerminationTiming == .immediate else {
            check("会话和直接模式初始化", false)
            return results
        }
        @discardableResult
        func step(_ seconds: TimeInterval) -> Task<Void, Never>? {
            timeline.advance(seconds)
            model.lastSampleDate = timeline.date
            model.acceptTemperatureReading(TemperatureReading(celsius: 75, sensorCount: 1,
                source: .appleSMC, date: timeline.date), generation: model.generation)
            return model.evaluateAutomaticProtection()
        }
        var quietBeforeThreshold = step(0) == nil
            && !model.isActionBusy && !model.autoProtectionCountdownActive && !notice.isPresented
        for _ in 0..<39 {
            quietBeforeThreshold = quietBeforeThreshold && step(30) == nil
                && !model.isActionBusy && !model.autoProtectionCountdownActive && !notice.isPresented
        }
        check("二十分钟证据期间不提前动作、不弹倒计时", quietBeforeThreshold)
        model.ready = true
        let queued = step(30)
        check("达到门槛后直接进入执行且没有 30 秒令牌",
            queued != nil && !model.autoProtectionCountdownActive && !notice.isPresented
                && model.autoCountdownDeadlineUptime == nil && model.isActionBusy)
        await queued?.value
        check("真实最终身份门禁后结束私有目标",
            !model.isActionBusy && !notice.isPresented
                && model.events.last?.message.hasPrefix("已强制结束") == true
                && NativeSampler.process(pid: process.pid) == nil)
        await model.prepareForTermination()
        return results
    }

    /// Negative integration counterpart for the high-risk timing choice. The
    /// engine first reaches a direct `.enforce` decision with a continuous
    /// low-I/O fixture, then the coordinator receives a latest frame showing
    /// real disk activity. The final action gate must reject the target and
    /// leave the private fixture alive; a stale direct decision is never an
    /// execution permission.
    static func automaticImmediateLowIORevalidationRegression(process: AppProcess,
        dataDirectory: URL) async -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        let timeline = AutomaticProtectionTestClock()
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .enforce,
                automaticTerminationScope: .clearIdle, automaticTerminationTiming: .immediate),
            preferences: InMemoryPreferences(), automaticClock: timeline.clock,
            countdownNotice: RecordingAutomaticCountdown())
        defer { model.ready = false; model.timer?.invalidate() }
        model.ready = true
        model.temperatureRefreshInFlight = true
        model.sampling = true
        model.processes = [process]
        model.lastSampleDate = timeline.date
        model.confirmAutomaticProtectionForSession()
        var results: [(name: String, passed: Bool)] = []
        func check(_ name: String, _ passed: Bool) { results.append(("直接自动结束：" + name, passed)) }
        guard model.automaticSessionConfirmed else {
            check("低 I/O 最终复核会话初始化", false)
            return results
        }

        @discardableResult
        func observe(_ seconds: TimeInterval) -> AutoProtectionDecision {
            timeline.advance(seconds)
            model.lastSampleDate = timeline.date
            model.acceptTemperatureReading(TemperatureReading(celsius: 75, sensorCount: 1,
                source: .appleSMC, date: timeline.date), generation: model.generation)
            return model.automaticProtection.observe(now: timeline.date, temperature: 75,
                temperatureDate: timeline.date, processes: model.processes,
                settings: model.autoProtectionSettings, isScanning: false,
                authorizedTargets: Set(model.automaticTerminationGrants.keys))
        }

        var decision = observe(0)
        for _ in 0..<40 { decision = observe(30) }
        guard decision.kind == .enforce else {
            check("低 I/O 连续证据先达到直接执行决定", false)
            return results
        }

        let noisy = AppProcess(id: process.id, memberIdentities: process.memberIdentities,
            pid: process.pid, parentPID: process.parentPID, uid: process.uid, name: process.name,
            displayName: process.displayName, bundleIdentifier: process.bundleIdentifier,
            path: process.path, cpuPercent: process.cpuPercent,
            wakeupsPerSecond: process.wakeupsPerSecond,
            diskBytesPerSecond: 2 * 1_048_576, residentBytes: process.residentBytes,
            isForeground: process.isForeground, isBackground: process.isBackground,
            isSystem: process.isSystem, isProtected: process.isProtected,
            protectionReason: process.protectionReason, isSoftLimited: process.isSoftLimited,
            risk: process.risk, confidence: process.confidence, evidence: process.evidence,
            recommendation: process.recommendation, executablePath: process.executablePath,
            wakeupsAvailable: process.wakeupsAvailable, diskAvailable: process.diskAvailable,
            automaticContextBlockReason: process.automaticContextBlockReason)
        model.processes = [noisy]
        let result = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        let rejected: Bool
        switch result {
        case .success: rejected = false
        case .failure(let message): rejected = message.contains("低 I/O")
        }
        check("排队后最新 I/O 活跃会拒绝直接结束且保留目标",
            rejected && NativeSampler.process(pid: process.pid) != nil
                && !model.isActionBusy)
        await model.prepareForTermination()
        return results
    }

    /// Exercises the exact global stop and re-enable controls with in-memory
    /// persistence. Only a rejected final-action call sees a private test child.
    static func globalStopRegressions(process: AppProcess, dataDirectory: URL) async
        -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        var savedModes: [AutoProtectionMode] = []
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { interactive }, initialAutomaticSettings: AutoProtectionSettings(mode: .enforce),
            automaticSettingsWriter: { savedModes.append($0.mode) }, preferences: InMemoryPreferences())
        defer { model.ready = false }
        model.temperatureRefreshInFlight = true
        model.processes = [process]
        model.lastSampleDate = Date()
        model.temperature = TemperatureReading(celsius: 75, sensorCount: 1, source: .appleSMC, date: Date())
        model.automaticSessionConfirmed = true
        guard let grant = AutomaticTerminationGrant(process: process) else {
            return [("全局停止夹具具有完整身份", false)]
        }
        model.automaticTerminationGrants[grant] = process.displayName
        let start = Date(timeIntervalSince1970: 600_000)
        var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
        for seconds in stride(from: 0.0, through: 1_200.0, by: 30.0) {
            let now = start.addingTimeInterval(seconds)
            decision = model.automaticProtection.observe(now: now, temperature: 75, temperatureDate: now,
                processes: [process], settings: model.autoProtectionSettings,
                isScanning: false, authorizedTargets: [grant])
        }
        var results = [("全局停止回归从默认二十分钟有效倒计时开始", decision.kind == .countdown)]
        var safePresetWrites: [AutoProtectionSettings] = []
        let safePresetModel = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("safe-idle-preset"),
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .observe),
            automaticSettingsWriter: { safePresetWrites.append($0) },
            preferences: InMemoryPreferences())
        safePresetModel.askToEnableSafeIdleAutomation()
        let asked = safePresetModel.showSafeIdleAutomationConfirmation
        if let confirmation = safePresetModel.pendingAutomaticPolicyConfirmation {
            safePresetModel.confirmSafeIdleAutomation(confirmation)
        }
        results.append(("安全空转预设一次确认同时开启范围、自动保护和本次会话",
            asked && safePresetModel.autoProtectionSettings.mode == .enforce
                && safePresetModel.autoProtectionSettings.automaticTerminationScope == .clearIdle
                && safePresetModel.automaticSessionConfirmed
                && safePresetModel.automaticTerminationGrants.isEmpty
                && safePresetWrites.count == 1))
        var permissiveLegacy = AutoProtectionSettings(mode: .observe)
        permissiveLegacy.anomalyTemperatureCelsius = 60
        permissiveLegacy.enforceTemperatureCelsius = 65
        permissiveLegacy.anomalyDuration = 120
        permissiveLegacy.enforceDuration = 120
        permissiveLegacy.minimumCPUPercent = 40
        permissiveLegacy.recentForegroundGrace = 0
        permissiveLegacy.cooldown = 60
        let hardenedModel = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("threshold-hardening"),
            sessionSnapshot: { interactive }, initialAutomaticSettings: permissiveLegacy,
            preferences: InMemoryPreferences())
        hardenedModel.askToEnableSafeIdleAutomation()
        if let confirmation = hardenedModel.pendingAutomaticPolicyConfirmation {
            hardenedModel.confirmSafeIdleAutomation(confirmation)
        }
        let hardened = hardenedModel.autoProtectionSettings
        results.append(("确认自动结束时把旧偏好收紧到公开安全底线",
            hardened.mode == .enforce && hardened.automaticTerminationScope == .clearIdle
                && hardened.anomalyTemperatureCelsius >= 65
                && hardened.enforceTemperatureCelsius >= 70
                && hardened.anomalyDuration >= 300
                && hardened.enforceDuration >= 1_200
                && hardened.minimumCPUPercent >= 80
                && hardened.recentForegroundGrace >= 1_800
                && hardened.cooldown >= 1_800))
        hardenedModel.ready = false
        var persistedEnforce = permissiveLegacy
        persistedEnforce.mode = .enforce
        let persistedEnforceModel = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("persisted-enforce-hardening"),
            sessionSnapshot: { interactive }, initialAutomaticSettings: persistedEnforce,
            preferences: InMemoryPreferences())
        persistedEnforceModel.confirmAutomaticProtectionForSession()
        let persisted = persistedEnforceModel.autoProtectionSettings
        results.append(("旧的已启用模式在会话确认时也收紧安全底线",
            persistedEnforceModel.automaticSessionConfirmed
                && persisted.anomalyTemperatureCelsius >= 65
                && persisted.enforceTemperatureCelsius >= 70
                && persisted.anomalyDuration >= 300
                && persisted.enforceDuration >= 1_200
                && persisted.minimumCPUPercent >= 80
                && persisted.recentForegroundGrace >= 1_800
                && persisted.cooldown >= 1_800))
        persistedEnforceModel.ready = false
        safePresetModel.ready = false
        let scopeStatusModel = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("scope-status"),
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .advise),
            automaticSettingsWriter: { _ in }, preferences: InMemoryPreferences())
        scopeStatusModel.setAutomaticTerminationScope(.clearIdleWithEphemeralCLI)
        if let confirmation = scopeStatusModel.pendingAutomaticPolicyConfirmation {
            scopeStatusModel.confirmAutomaticScopeEnable(confirmation)
        }
        results.append(("自动处置范围状态显示实际名称而非占位符",
            scopeStatusModel.autoProtectionStatus.contains("安全临时命令行")
                && !scopeStatusModel.autoProtectionStatus.contains("scope.title")))
        results.append(("菜单栏无授权提示与自动处置范围一致",
            AutomaticTerminationScope.explicitGrant.emptyGrantSummary.contains("不会执行")
                && AutomaticTerminationScope.clearIdle.emptyGrantSummary.contains("仍可能自动结束")
                && AutomaticTerminationScope.clearIdleWithEphemeralCLI.emptyGrantSummary.contains("安全临时命令行")))
        let ephemeralScopeModel = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("ephemeral-scope-preset"),
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .enforce,
                automaticTerminationScope: .clearIdleWithEphemeralCLI),
            automaticSettingsWriter: { _ in }, preferences: InMemoryPreferences())
        ephemeralScopeModel.askToEnableSafeIdleAutomation()
        results.append(("已启用安全临时命令行范围时不再显示会收窄范围的重复预设",
            !ephemeralScopeModel.showSafeIdleAutomationConfirmation
                && ephemeralScopeModel.pendingAutomaticPolicyConfirmation == nil
                && ephemeralScopeModel.autoProtectionSettings.automaticTerminationScope
                    == .clearIdleWithEphemeralCLI))
        ephemeralScopeModel.ready = false
        scopeStatusModel.ready = false
        model.autoProtectionCountdownActive = true
        model.autoCountdownKey = process.groupKey
        model.autoCountdownDeadlineUptime = ProcessInfo.processInfo.systemUptime + 30
        model.showAutoProtectionConfirmation = true
        model.askToAllowAutomaticTermination(process)
        model.isActionBusy = true // an unrelated action must not disable the stop control
        let queuedEpoch = model.autoActionEpoch
        let originalNotifications = model.notificationsEnabled
        model.stopAutomaticTermination()
        results.append(("全局停止保存只提醒模式且立即显示停止状态",
            savedModes == [.advise] && model.autoProtectionSettings.mode == .advise
                && model.autoProtectionStatus.contains("自动结束已停止")))
        results.append(("另一项操作忙时全局停止仍撤销令牌倒计时及待确认弹窗",
            queuedEpoch != model.autoActionEpoch && !model.autoProtectionCountdownActive
                && model.autoCountdownDeadlineUptime == nil && model.autoCountdownKey == nil
                && !model.showAutoProtectionConfirmation && !model.showAutomaticPermissionConfirmation
                && model.pendingAutomaticPermission == nil && model.isActionBusy))
        model.ready = true
        let queued = await model.executeAutomaticProtection(process, epoch: queuedEpoch)
        let current = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        func rejected(_ result: ActionResult) -> Bool {
            if case .failure(let message) = result {
                return message == "自动保护已取消：倒计时后目标状态已变化或最新证据已过期。"
            }
            return false
        }
        results.append(("停止后旧令牌和新令牌都不能执行且私有目标保持原身份",
            rejected(queued) && rejected(current)
                && NativeSampler.process(pid: process.pid)?.identity == process.id))
        results.append(("全局停止不暂停普通监测或删除已授予的身份记录",
            model.ready && !model.sleeping && model.hasAutomaticPermission(process)))
        model.ready = false
        var neverEnforced = true
        for seconds in stride(from: 0.0, through: 1_230.0, by: 30.0) {
            let now = start.addingTimeInterval(5_000 + seconds)
            decision = model.automaticProtection.observe(now: now, temperature: 75, temperatureDate: now,
                processes: [process], settings: model.autoProtectionSettings,
                isScanning: false, authorizedTargets: [grant])
            neverEnforced = neverEnforced && decision.kind != .countdown && decision.kind != .enforce
        }
        results.append(("停止后仍输出持续异常但不再倒计时且保留通知偏好",
            neverEnforced && decision.kind == .anomaly && model.notificationsEnabled == originalNotifications))
        model.stopAutomaticTermination()
        results.append(("重复停止幂等且不重复写设置", savedModes == [.advise]))
        model.setAutoProtectionMode(.enforce)
        results.append(("重新选择自动模式仍须确认而不会隐式开启",
            model.showAutoProtectionConfirmation && model.autoProtectionSettings.mode == .advise
                && savedModes == [.advise]))
        if let confirmation = model.pendingAutomaticPolicyConfirmation {
            model.confirmAutoProtectionEnable(confirmation)
        }
        let afterRestart = model.automaticProtection.observe(now: start.addingTimeInterval(1_230),
            temperature: 75, processes: [process], settings: model.autoProtectionSettings,
            isScanning: false, authorizedTargets: [grant])
        results.append(("重新确认后从零积累而不继承停止前的二十分钟",
            model.autoProtectionSettings.mode == .enforce && model.automaticSessionConfirmed
                && !model.showAutoProtectionConfirmation && afterRestart.kind == .none
                && savedModes == [.advise, .enforce]))
        model.setAutoProtectionMode(.observe)
        model.stopAutomaticTermination()
        results.append(("仅观察时重复停止不会擅自开启提醒或系统通知",
            model.autoProtectionSettings.mode == .observe && model.notificationsEnabled == originalNotifications
                && savedModes == [.advise, .enforce, .observe]))
        results.append(("全局停止回归不创建状态文件或采样计时器",
            model.timer == nil && !FileManager.default.fileExists(atPath: dataDirectory.path)))
        return results
    }

    /// One hundred synchronous model-level pause/resume cycles. No system
    /// sleep, distributed notification, sensor, signal or preferences write.
    /// The timer is scheduled far in the future then invalidated synchronously
    /// before yielding the main actor. This does not replace physical sleep QA.
    static func lifecycleCycleRegressions(process: AppProcess, dataDirectory: URL)
        -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { interactive }, initialAutomaticSettings: AutoProtectionSettings(mode: .observe),
            preferences: InMemoryPreferences())
        model.temperatureRefreshInFlight = true
        let observerCount = model.observers.count
        var settings = AutoProtectionSettings(mode: .enforce)
        guard let grant = AutomaticTerminationGrant(process: process) else {
            return [("生命周期夹具具有完整身份授权", false)]
        }
        settings.anomalyDuration = 60
        settings.enforceDuration = 120
        let start = Date().addingTimeInterval(-150_000)
        var positiveControls = 0
        var revokedCycles = 0
        var resumedCycles = 0
        var timerCycles = 0
        var independentReasons = true
        var boundedHistory = true
        var stableObservers = true
        var previousTimer: Timer?
        defer { model.ready = false; model.timer?.invalidate() }

        for cycle in 0..<100 {
            model.automaticProtection = AutomaticProtectionEngine()
            let point = start.addingTimeInterval(Double(cycle) * 1_200)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 120.0, by: 30.0) {
                decision = model.automaticProtection.observe(now: point.addingTimeInterval(offset),
                    temperature: 75, processes: [process], settings: settings, isScanning: false,
                    authorizedTargets: [grant])
            }
            if decision.kind == .countdown { positiveControls += 1 }
            model.autoProtectionCountdownActive = true
            model.autoCountdownKey = process.groupKey
            model.autoCountdownDeadlineUptime = ProcessInfo.processInfo.systemUptime + 30
            model.automaticSessionConfirmed = true
            model.temperature = TemperatureReading(celsius: 75, sensorCount: 1, source: .appleSMC, date: point)
            model.fullReset = false
            let queuedEpoch = model.autoActionEpoch
            let initialGeneration = model.generation

            model.ready = true
            model.schedule(after: 3_600)
            let firstTimer = model.timer
            model.schedule(after: 3_600)
            let secondTimer = model.timer
            model.ready = false
            let timersReplaced = firstTimer?.isValid == false && secondTimer?.isValid == true
                && (previousTimer == nil || previousTimer?.isValid == false)

            model.willSleep()
            model.setSessionInactive(.displaySleep, inactive: true)
            model.setSessionInactive(.sessionInactive, inactive: true)
            model.setSessionInactive(.screenLocked, inactive: true)
            if model.autoActionEpoch != queuedEpoch && !model.autoProtectionCountdownActive
                && model.autoCountdownKey == nil && model.autoCountdownDeadlineUptime == nil
                && !model.countdownNotice.isPresented && model.temperature == nil
                && !model.automaticSessionConfirmed && model.generation == initialGeneration + 1 {
                revokedCycles += 1
            }
            if timersReplaced && secondTimer?.isValid == false { timerCycles += 1 }
            previousTimer = secondTimer

            let reasons = ProtectionSessionGate.Reason.allCases
            for index in 0..<reasons.count {
                let reason = reasons[(index + cycle) % reasons.count]
                switch reason {
                case .systemSleep: model.didWake()
                case .screenLocked: model.screenDidUnlock()
                default: model.setSessionInactive(reason, inactive: false)
                }
                independentReasons = independentReasons && (model.sleeping == (index < reasons.count - 1))
            }
            let resumed = model.automaticProtection.observe(now: point.addingTimeInterval(150),
                temperature: 75, processes: [process], settings: settings, isScanning: false,
                authorizedTargets: [grant])
            if !model.sleeping && model.fullReset && model.previousResultDate == nil
                && model.generation == initialGeneration + 2 && resumed.kind == .none
                && model.timer?.isValid != true && !model.sampling {
                resumedCycles += 1
            }
            // Exercise the production apply -> TrendBuffer path, not a second
            // test-only history implementation. The model is never ready to act.
            for minute in 0..<20 {
                model.apply(MonitoringResult(date: point.addingTimeInterval(Double(minute) * 60),
                    thermal: .nominal, cpu: 5, processes: [], loadAverage: 0,
                    totalProcessCount: 0, readableProcessCount: 0,
                    ownCPU: 0, ownMemory: 0, elapsedMilliseconds: 0))
                boundedHistory = boundedHistory && model.history.count <= 1_440
            }
            stableObservers = stableObservers && model.observers.count == observerCount
        }
        return [
            ("100 次生命周期模拟均从有效倒计时阳性对照开始", positiveControls == 100),
            ("100 次暂停撤销动作令牌倒计时温度和会话确认", revokedCycles == 100),
            ("100 次交错恢复中所有独立暂停原因均保持有效", independentReasons),
            ("100 次恢复要求新采样基线且不继承旧高温证据", resumedCycles == 100),
            ("100 次调度替换和暂停不遗留有效采样计时器", timerCycles == 100),
            ("100 次生命周期处理不增加通知订阅或意外写入文件",
             stableObservers && !FileManager.default.fileExists(atPath: dataDirectory.path)),
            ("2000 个模拟分钟经过真实 apply 路径后趋势保持 1440 点上限",
             boundedHistory && model.history.count == 1_440)
        ]
    }

    /// Uses only the integration suite's private sleep child. No sampler,
    /// window, preference write, or real user session event is started here.
    /// The final-action negative cases are checked against this model's error
    /// (not the executor's), and require the child identity to remain alive.
    static func permissionAndSessionRegressions(process: AppProcess, dataDirectory: URL) async
        -> [(name: String, passed: Bool)] {
        var results = ProtectionSessionSnapshotRegression.results()
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        var snapshot = interactive
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory,
            sessionSnapshot: { snapshot }, initialAutomaticSettings: AutoProtectionSettings(mode: .enforce),
            preferences: InMemoryPreferences())
        defer { model.ready = false }
        model.temperatureRefreshInFlight = true
        model.processes = [process]
        model.lastSampleDate = Date()
        model.temperature = TemperatureReading(celsius: 75, sensorCount: 1, source: .appleSMC, date: Date())
        results.append(("即使公开快照正常，冷启动仍不能假定已解锁", !model.automaticSessionConfirmed && !model.sleeping))
        model.askToAllowAutomaticTermination(process)
        model.cancelAutomaticPermission()
        results.append(("取消授权确认不产生权限", model.automaticTerminationGrants.isEmpty))
        model.askToAllowAutomaticTermination(process)
        model.processes = []
        model.confirmAutomaticPermission()
        results.append(("确认时目标已消失不授予权限", model.automaticTerminationGrants.isEmpty))
        model.processes = [process]
        let epochBeforeGrant = model.autoActionEpoch
        model.askToAllowAutomaticTermination(process)
        model.confirmAutomaticPermission()
        results.append(("明确确认仅授予当前任务且撤销旧动作令牌",
            model.hasAutomaticPermission(process) && model.autoActionEpoch != epochBeforeGrant
                && !model.autoProtectionCountdownActive && !model.automaticSessionConfirmed))
        guard let grant = AutomaticTerminationGrant(process: process), model.hasAutomaticPermission(process) else {
            return results + [("本次授权测试前提成立", false)]
        }

        func declinedByFinalGate(_ result: ActionResult) -> Bool {
            guard case .failure(let message) = result else { return false }
            return (message == "自动保护已取消：倒计时后目标状态已变化或最新证据已过期。"
                || message == "自动保护已取消：最新证据不再满足连续低 I/O 空转、温度或 CPU 时长门槛。")
                && NativeSampler.process(pid: process.pid)?.identity == process.id
        }

        model.ready = true
        let coldResult = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        results.append(("最终动作门禁拒绝冷启动未确认会话并保留私有夹具", declinedByFinalGate(coldResult)))
        model.ready = false
        model.confirmAutomaticProtectionForSession()
        results.append(("明确本地确认可解除冷启动待确认状态", model.automaticSessionConfirmed))

        let unknownStart = MonitorModel(autoStart: false, dataDirectory: dataDirectory.appendingPathComponent("unlock"),
            sessionSnapshot: { interactive }, initialAutomaticSettings: AutoProtectionSettings(mode: .enforce),
            preferences: InMemoryPreferences())
        let start = Date(timeIntervalSince1970: 500_000)
        for offset in stride(from: 0.0, through: 1_200.0, by: 30.0) {
            _ = unknownStart.automaticProtection.observe(now: start.addingTimeInterval(offset), temperature: 75,
                processes: [process], settings: AutoProtectionSettings(mode: .advise), isScanning: false,
                authorizedTargets: [grant])
        }
        var withoutReset = unknownStart.automaticProtection
        let wouldCountdown = withoutReset.observe(now: start.addingTimeInterval(1_230), temperature: 75,
            processes: [process], settings: AutoProtectionSettings(mode: .enforce), isScanning: false,
            authorizedTargets: [grant]).kind == .countdown
        unknownStart.screenDidUnlock()
        let afterUnlock = unknownStart.automaticProtection.observe(now: start.addingTimeInterval(1_230), temperature: 75,
            processes: [process], settings: AutoProtectionSettings(mode: .enforce), isScanning: false,
            authorizedTargets: [grant])
        results.append(("冷启动后解锁不会继承待确认期间积累的二十分钟",
            wouldCountdown && unknownStart.automaticSessionConfirmed && afterUnlock.kind == .none))

        model.ready = true
        snapshot = ProtectionSessionSnapshot(onConsole: false, loginDone: true, anyDisplayAwake: true)
        let changedSession = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        results.append(("最终执行重新查询会话并在失败时撤销会话确认",
            declinedByFinalGate(changedSession) && !model.automaticSessionConfirmed))
        snapshot = interactive
        results.append(("快照恢复不自行恢复会话权限或继承等待证据", !model.automaticSessionIsUsable()))
        model.ready = false
        model.confirmAutomaticProtectionForSession()
        results.append(("快照失败后可通过明确确认重新开始", model.automaticSessionConfirmed))
        snapshot = ProtectionSessionSnapshot(onConsole: nil, loginDone: true, anyDisplayAwake: true)
        model.evaluateAutomaticProtection()
        results.append(("评估阶段发现快照未知也撤销已确认状态", !model.automaticSessionConfirmed))
        snapshot = interactive
        model.confirmAutomaticProtectionForSession()
        let queuedEpoch = model.autoActionEpoch
        model.removeAutomaticPermission(grant)
        model.ready = true
        let revokedEpoch = await model.executeAutomaticProtection(process, epoch: queuedEpoch)
        results.append(("撤销本次授权使排队动作令牌失效", declinedByFinalGate(revokedEpoch)))
        let revokedAuthority = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        results.append(("即使拿到新令牌，最终执行仍拒绝已撤销的授权", declinedByFinalGate(revokedAuthority)))
        model.automaticProtection.recordForegroundUse(process, at: Date().addingTimeInterval(-3_600))
        let historyOnly = await model.executeAutomaticProtection(process, epoch: model.autoActionEpoch)
        results.append(("最终动作门禁不把过去前台记录当授权且私有目标仍在", declinedByFinalGate(historyOnly)))
        model.ready = false

        model.askToAllowAutomaticTermination(process)
        model.confirmAutomaticPermission()
        model.processes = []
        model.pruneAutomaticPermissions()
        model.processes = [process]
        results.append(("缺失任务帧使本次授权失效且不会自行恢复", !model.hasAutomaticPermission(process)))
        model.askToAllowAutomaticTermination(process)
        model.confirmAutomaticPermission()
        model.protectedApps[process.protectionKey] = process.displayName
        model.pruneAutomaticPermissions()
        results.append(("保护名单优先于本次授权且移除授权", !model.hasAutomaticPermission(process)))

        model.setSessionInactive(.screenLocked, inactive: true)
        model.setSessionInactive(.displaySleep, inactive: true)
        model.setSessionInactive(.displaySleep, inactive: false)
        model.confirmAutomaticProtectionForSession()
        results.append(("正常快照和亮屏不能覆盖仍记录着的锁屏原因", model.sleeping && !model.automaticSessionConfirmed))
        for coldSnapshot in [
            ProtectionSessionSnapshot(onConsole: false, loginDone: true, anyDisplayAwake: true),
            ProtectionSessionSnapshot(onConsole: true, loginDone: false, anyDisplayAwake: true),
            ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: false)
        ] {
            let cold = MonitorModel(autoStart: false, dataDirectory: dataDirectory.appendingPathComponent("cold"),
                sessionSnapshot: { coldSnapshot }, preferences: InMemoryPreferences())
            results.append(("启动前已存在的非交互状态被初始化为暂停", cold.sleeping && !cold.automaticSessionConfirmed))
        }
        return results
    }

    static func invalidFrameRevocationRegression(dataDirectory: URL) -> Bool {
        let model = MonitorModel(autoStart: false, dataDirectory: dataDirectory, preferences: InMemoryPreferences())
        model.temperatureRefreshInFlight = true
        model.autoProtectionCountdownActive = true
        model.autoCountdownKey = "test-only-pending-action"
        model.autoCountdownDeadlineUptime = ProcessInfo.processInfo.systemUptime + 30
        let queuedEpoch = model.autoActionEpoch
        model.apply(MonitoringResult(date: Date(), thermal: .nominal, cpu: nil,
            processes: [], loadAverage: 0, totalProcessCount: 0, readableProcessCount: 0,
            ownCPU: 0, ownMemory: 0, elapsedMilliseconds: 0))
        return model.autoActionEpoch != queuedEpoch
            && !model.autoProtectionCountdownActive && model.autoCountdownKey == nil
            && model.autoCountdownDeadlineUptime == nil && !model.countdownNotice.isPresented
    }
}

enum ReportMerger {
    static func merge(observed: [AppProcess], deep: [AppProcess]) -> [AppProcess] {
        var values = Dictionary(observed.map { ($0.groupKey, $0) }, uniquingKeysWith: { old, _ in old })
        for item in deep where values[item.groupKey] == nil {
            values[item.groupKey] = item.withCPU(item.cpuPercent, evidence: ["仅系统深扫快照（约 1 秒），非观察期均值"] + item.evidence)
        }
        return values.values.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
