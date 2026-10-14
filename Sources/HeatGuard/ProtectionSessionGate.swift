/// Independent reasons why a warning cannot be seen or acted on. A display
/// waking does not unlock the screen; a system wake does not activate a user
/// session. Only the matching resume event may clear each reason.
struct ProtectionSessionGate: Sendable {
    enum Reason: CaseIterable, Hashable, Sendable {
        case systemSleep
        case displaySleep
        case sessionInactive
        case screenLocked
    }

    private(set) var inactiveReasons: Set<Reason> = []
    var isPaused: Bool { !inactiveReasons.isEmpty }

    mutating func set(_ reason: Reason, inactive: Bool) {
        if inactive { inactiveReasons.insert(reason) }
        else { inactiveReasons.remove(reason) }
    }
}
