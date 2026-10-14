/// Pure regression cases. No notifications, processes, settings or windows
/// are touched. SelfTest can consume these alongside its other check results.
enum ProtectionSessionGateRegression {
    static func results() -> [(name: String, passed: Bool)] {
        var locked = ProtectionSessionGate()
        locked.set(.screenLocked, inactive: true)
        locked.set(.displaySleep, inactive: true)
        locked.set(.displaySleep, inactive: false)
        let displayWakeKeepsLock = locked.isPaused
            && locked.inactiveReasons == [.screenLocked]
        locked.set(.systemSleep, inactive: false)
        let unrelatedWakeKeepsLock = locked.isPaused
        locked.set(.screenLocked, inactive: false)
        let unlockResumes = !locked.isPaused

        var allReasons = ProtectionSessionGate()
        ProtectionSessionGate.Reason.allCases.forEach { allReasons.set($0, inactive: true) }
        var eachReasonRequired = true
        for reason in ProtectionSessionGate.Reason.allCases {
            allReasons.set(reason, inactive: false)
            if reason != ProtectionSessionGate.Reason.allCases.last {
                eachReasonRequired = eachReasonRequired && allReasons.isPaused
            }
        }
        eachReasonRequired = eachReasonRequired && !allReasons.isPaused

        var repeated = ProtectionSessionGate()
        repeated.set(.sessionInactive, inactive: true)
        repeated.set(.sessionInactive, inactive: true)
        repeated.set(.displaySleep, inactive: false)
        let repeatedInactiveIsIdempotent = repeated.inactiveReasons == [.sessionInactive]
        repeated.set(.sessionInactive, inactive: false)
        repeated.set(.sessionInactive, inactive: false)

        return [
            ("锁屏后的屏幕唤醒或系统唤醒不能提前恢复自动保护",
             displayWakeKeepsLock && unrelatedWakeKeepsLock && unlockResumes),
            ("所有非交互原因都解除后才能恢复自动保护", eachReasonRequired),
            ("重复暂停和无关唤醒通知不会错误解除会话保护",
             repeatedInactiveIsIdempotent && !repeated.isPaused)
        ]
    }
}
