import Darwin

/// Bounded ancestry evidence for action-time foreground protection. This gate
/// reads only through its injected lookup and never sends a signal. Missing or
/// inconsistent ancestry is unknown, not evidence that a target is unrelated.
enum ForegroundAncestorGate {
    enum State: Equatable {
        case clear
        case foreground
        case unknown
    }

    /// Examines at most 64 ancestor nodes, including terminal nodes. An
    /// ancestor discovered by the 64th lookup is not evaluated as a 65th node.
    static func evaluate(parentPID: pid_t, foregroundPID: pid_t?, ownPID: pid_t,
                         parentLookup: (pid_t) -> pid_t?) -> State {
        // Preserve the existing no-foreground behavior. This result does not
        // grant action authority: all other action checks still have to pass.
        guard let foregroundPID, foregroundPID > 1 else { return .clear }
        var current = parentPID
        var visited: Set<pid_t> = []
        for _ in 0..<64 {
            guard current > 0 else { return .unknown }
            if current == 1 { return .clear }
            // Keep private children isolated from the terminal/IDE hosting
            // the test monitor; its own PID takes precedence over foreground.
            if current == ownPID { return .clear }
            if current == foregroundPID { return .foreground }
            guard visited.insert(current).inserted else { return .unknown }
            guard let parent = parentLookup(current) else { return .unknown }
            current = parent
        }
        return .unknown
    }
}
