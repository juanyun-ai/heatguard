import Foundation

/// Only classifications derived from immutable sampling inputs belong here.
/// Ownership, foreground state, CPU, user protection and action eligibility
/// must still be evaluated afresh for every frame.
struct StaticProcessFacts: Sendable {
    let isSystemPath: Bool
    let advice: KnowledgeAdvice
    let excludesAutomaticProtection: Bool
}

/// Worker-owned, value-semantic cache with no global state or synchronization.
/// A process can exec a new image without changing its PID/start identity, and
/// metadata can become available later, so identity alone is not a valid key.
struct StaticProcessFactsCache: Sendable {
    static let capacity = 2_048

    private struct Key: Hashable, Sendable {
        let identity: ProcessIdentity
        let name: String
        let path: String
        let bundleIdentifier: String?
    }

    private var entries: [Key: StaticProcessFacts] = [:]

    var count: Int { entries.count }

    mutating func facts(identity: ProcessIdentity, name: String, path: String,
                        bundleIdentifier: String?) -> StaticProcessFacts {
        let key = Key(identity: identity, name: name, path: path,
                      bundleIdentifier: bundleIdentifier)
        if let cached = entries[key] { return cached }

        let facts = StaticProcessFacts(
            isSystemPath: ProcessPathPolicy.isSystemExecutable(path),
            advice: LocalKnowledgeBase.advice(name: name, path: path,
                                              bundleIdentifier: bundleIdentifier),
            excludesAutomaticProtection: LocalKnowledgeBase.isAutomaticProtectionExcluded(
                name: name, path: path, bundleIdentifier: bundleIdentifier)
        )
        // Old processes need no eviction bookkeeping. On overflow discard
        // classification results, never evidence or live protection state.
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = facts
        return facts
    }
}
