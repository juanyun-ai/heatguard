import Foundation

/// Model-level user-intent regressions. No sampler, live target, settings
/// database, system notification, or action executor is started here.
@MainActor
enum AutomaticControlRegression {
    static func results(dataDirectory: URL) -> [(name: String, passed: Bool)] {
        let interactive = ProtectionSessionSnapshot(onConsole: true, loginDone: true, anyDisplayAwake: true)
        var results: [(name: String, passed: Bool)] = []
        func model(_ name: String, preferences: HeatGuardPreferences = InMemoryPreferences()) -> MonitorModel {
            MonitorModel(autoStart: false, dataDirectory: dataDirectory.appendingPathComponent(name),
                sessionSnapshot: { interactive }, preferences: preferences)
        }

        let stopped = model("stopped-preset")
        stopped.askToEnableSafeIdleAutomation()
        let opened = stopped.showSafeIdleAutomationConfirmation
        stopped.stopAutomaticTermination()
        results.append(("自动确认：全局停止同时关闭安全空转预设弹窗",
            opened && !stopped.showSafeIdleAutomationConfirmation))
        if let confirmation = stopped.pendingAutomaticPolicyConfirmation {
            stopped.confirmSafeIdleAutomation(confirmation)
        }
        results.append(("自动确认：停止后迟到的预设确认不得重新启用",
            stopped.autoProtectionSettings.mode == .observe
                && stopped.autoProtectionSettings.automaticTerminationScope == .explicitGrant
                && !stopped.automaticSessionConfirmed))

        let cancelledMode = model("cancelled-mode")
        cancelledMode.setAutoProtectionMode(.enforce)
        if let confirmation = cancelledMode.pendingAutomaticPolicyConfirmation {
            cancelledMode.cancelAutomaticPolicyConfirmation(confirmation)
            cancelledMode.confirmAutoProtectionEnable(confirmation)
        }
        results.append(("自动确认：取消模式弹窗后的迟到确认不得启用",
            cancelledMode.autoProtectionSettings.mode == .observe))

        let cancelledScope = model("cancelled-scope")
        cancelledScope.setAutomaticTerminationScope(.clearIdleWithEphemeralCLI)
        if let confirmation = cancelledScope.pendingAutomaticPolicyConfirmation {
            cancelledScope.cancelAutomaticPolicyConfirmation(confirmation)
            cancelledScope.confirmAutomaticScopeEnable(confirmation)
        }
        results.append(("自动确认：取消范围弹窗后不得回落成默认空转授权",
            cancelledScope.autoProtectionSettings.automaticTerminationScope == .explicitGrant))

        let preferences = InMemoryPreferences()
        let legacy = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle,
            anomalyTemperatureCelsius: 60, enforceTemperatureCelsius: 65,
            anomalyDuration: 120, enforceDuration: 120, minimumCPUPercent: 40,
            recentForegroundGrace: 0, cooldown: 60)
        let savedData = try? JSONEncoder().encode(legacy)
        preferences.set(savedData, forKey: "autoProtectionSettings")
        let migrated = model("persisted-enforce", preferences: preferences)
        results.append(("自动迁移：加载低阈值已启用偏好时即收紧以覆盖后续解锁路径",
            migrated.autoProtectionSettings == legacy.hardenedForAutomaticUse
                && !migrated.automaticSessionConfirmed
                && preferences.data(forKey: "autoProtectionSettings") == savedData))
        results.append(("自动确认回归不创建历史或恢复文件",
            !FileManager.default.fileExists(atPath: dataDirectory.path)))

        let timingGuard = MonitorModel(autoStart: false,
            dataDirectory: dataDirectory.appendingPathComponent("timing-guard"),
            sessionSnapshot: { interactive },
            initialAutomaticSettings: AutoProtectionSettings(mode: .enforce,
                automaticTerminationScope: .clearIdle), preferences: InMemoryPreferences())
        timingGuard.setAutomaticTerminationTiming(.immediate)
        let immediatePrompted = timingGuard.showAutomaticTimingConfirmation
        let staleTimingToken = timingGuard.pendingAutomaticPolicyConfirmation
        if let staleTimingToken { timingGuard.cancelAutomaticTimingConfirmation(staleTimingToken) }
        if let staleTimingToken { timingGuard.confirmAutomaticTimingEnable(staleTimingToken) }
        let cancelledTimingStayedSafe = timingGuard.autoProtectionSettings.automaticTerminationTiming == .cancelWindow
            && !timingGuard.showAutomaticTimingConfirmation
        timingGuard.setAutomaticTerminationTiming(.immediate)
        if let freshTimingToken = timingGuard.pendingAutomaticPolicyConfirmation {
            timingGuard.confirmAutomaticTimingEnable(freshTimingToken)
        }
        let confirmedImmediate = timingGuard.autoProtectionSettings.automaticTerminationTiming == .immediate
            && timingGuard.showAutomaticTimingConfirmation == false
        timingGuard.stopAutomaticTermination()
        results.append(("直接自动结束：必须单独确认，迟到令牌无效，停止后恢复 30 秒窗口",
            immediatePrompted && cancelledTimingStayedSafe && confirmedImmediate
                && timingGuard.autoProtectionSettings.automaticTerminationTiming == .cancelWindow))

        let persistedDirectPreferences = InMemoryPreferences()
        var persistedDirect = AutoProtectionSettings(mode: .enforce,
            automaticTerminationScope: .clearIdle,
            automaticTerminationTiming: .immediate)
        persistedDirect.anomalyTemperatureCelsius = 65
        persistedDirect.enforceTemperatureCelsius = 70
        let persistedDirectData = try? JSONEncoder().encode(persistedDirect)
        persistedDirectPreferences.set(persistedDirectData, forKey: "autoProtectionSettings")
        let restoredDirect = model("persisted-direct", preferences: persistedDirectPreferences)
        restoredDirect.confirmAutomaticProtectionForSession()
        restoredDirect.setAutomaticTerminationTiming(.immediate)
        let promptedAfterRestore = restoredDirect.showAutomaticTimingConfirmation
        results.append(("高风险直接模式不会随重启静默恢复，重新启用仍需独立确认",
            restoredDirect.autoProtectionSettings.mode == .enforce
                && restoredDirect.autoProtectionSettings.automaticTerminationScope == .clearIdle
                && restoredDirect.autoProtectionSettings.automaticTerminationTiming == .cancelWindow
                && restoredDirect.automaticSessionConfirmed
                && promptedAfterRestore))
        return results
    }
}
