import Foundation

/// Background does not mean independent: an unnamed worker may still belong
/// to a protected app, IDE or terminal. Sampling uses one in-memory snapshot;
/// dispatch uses fresh native reads. No command arguments or documents needed.
enum ProcessAncestryGate {
    struct Node: Sendable {
        let identity: ProcessIdentity
        let parentPID: pid_t
        let uid: uid_t
        let name: String
        let path: String
        var bundleIdentifier: String?
        var protectedTask = false
        var excludedFromAutomatic = false
    }

    enum Verdict: Equatable, Sendable {
        case clear
        case protectedTask(String)
        case importantTask(String)
        case unknown

        var manualBlockReason: String? {
            switch self {
            case .clear, .importantTask: nil
            case .protectedTask(let name): "上级任务“\(name)”受保护，其后台子任务也不处理。"
            case .unknown: "无法完整核验上级任务身份，仅观察，不处理。"
            }
        }

        var automaticBlockReason: String? {
            switch self {
            case .clear: nil
            case .importantTask(let name): "来自工程或重要应用“\(name)”的后台任务，只提醒，不自动结束。"
            default: manualBlockReason
            }
        }
    }

    static func evaluate(parentPID: pid_t, ownPID: pid_t, protectedKeys: Set<String>,
                         lookup: (pid_t) -> Node?) -> Verdict {
        var current = parentPID
        var visited: Set<pid_t> = []
        var important: Verdict?
        for _ in 0..<64 {
            // launchd is the normal root, not inherited system protection.
            // HeatGuard only spawns its command helpers and private fixtures.
            if current == 1 || current == ownPID { return important ?? .clear }
            guard current > 1, visited.insert(current).inserted,
                  let node = lookup(current), node.identity.pid == current,
                  node.identity.startAbstime > 0, node.uid == getuid(),
                  node.path.hasPrefix("/"), !node.path.contains("\0") else { return .unknown }
            let root = AppResolver.appRoot(from: node.path)
            if protectedKeys.contains(node.path)
                || root.map(protectedKeys.contains) == true
                || node.bundleIdentifier.map(protectedKeys.contains) == true
                || node.protectedTask {
                return .protectedTask(node.name)
            }
            if node.excludedFromAutomatic { important = important ?? .importantTask(node.name) }
            current = node.parentPID
        }
        return .unknown
    }

    /// Used only at action time. Do not cache protection, identities or parent
    /// relationships between actions; a parent may exec or the task reparent.
    static func readNode(pid: pid_t) -> Node? {
        guard let raw = NativeSampler.process(pid: pid) else { return nil }
        let bundle = AppResolver.appRoot(from: raw.path).flatMap { Bundle(path: $0)?.bundleIdentifier }
        return Node(identity: raw.identity, parentPID: raw.parentPID, uid: raw.uid,
            name: raw.name, path: raw.path, bundleIdentifier: bundle,
            protectedTask: LocalKnowledgeBase.advice(name: raw.name, path: raw.path,
                bundleIdentifier: bundle).protected,
            excludedFromAutomatic: LocalKnowledgeBase.isAutomaticProtectionExcluded(
                name: raw.name, path: raw.path, bundleIdentifier: bundle))
    }
}

/// One frame only, capped by that frame's parent count. Many helpers share
/// ancestry, so re-use the result within the frame, never across observations.
struct SnapshotAncestryResolver {
    let nodes: [pid_t: ProcessAncestryGate.Node]
    let ownPID: pid_t
    let protectedKeys: Set<String>
    private struct CachedEvaluation: Sendable {
        let verdict: ProcessAncestryGate.Verdict
        let persistent: ProcessAncestryGate.Verdict?
        let userProtections: [String: String]
    }
    private var evaluations: [pid_t: CachedEvaluation] = [:]

    init(nodes: [pid_t: ProcessAncestryGate.Node], ownPID: pid_t, protectedKeys: Set<String>) {
        self.nodes = nodes
        self.ownPID = ownPID
        self.protectedKeys = protectedKeys
    }

    mutating func verdict(parentPID: pid_t) -> ProcessAncestryGate.Verdict {
        evaluation(parentPID: parentPID).verdict
    }

    /// Return only protection that comes from the observed ancestor itself,
    /// not from the user's current protected-key set. This lets the analyzer
    /// retain a conservative important-task association if that ancestor
    /// exits and the child is reparented, without making a removed user
    /// protection preference sticky.
    mutating func persistentVerdict(parentPID: pid_t) -> ProcessAncestryGate.Verdict? {
        evaluation(parentPID: parentPID).persistent
    }

    /// Record which still-enabled user rules supplied protection, separately
    /// from intrinsic important-task classification. If a child detaches,
    /// those rules can continue protecting its identity without becoming an
    /// irrevocable cached verdict. One bounded snapshot walk supplies both.
    mutating func evaluation(parentPID: pid_t) -> (verdict: ProcessAncestryGate.Verdict,
        persistent: ProcessAncestryGate.Verdict?, userProtections: [String: String]) {
        if let cached = evaluations[parentPID] {
            return (cached.verdict, cached.persistent, cached.userProtections)
        }
        // Most processes are direct children of launchd, and an owned helper
        // may point back at this monitor. Avoid allocating a visited set or
        // walking dictionaries for those safe roots.
        if parentPID == 1 || parentPID == ownPID {
            let cached = CachedEvaluation(verdict: .clear, persistent: nil, userProtections: [:])
            evaluations[parentPID] = cached
            return (.clear, nil, [:])
        }
        // The analyzer intentionally stores only parents referenced by this
        // frame. A missing immediate parent is already a fail-closed unknown;
        // there is no safe ancestor to discover without inventing a link.
        if parentPID <= 1 || nodes[parentPID] == nil {
            let cached = CachedEvaluation(verdict: .unknown, persistent: nil, userProtections: [:])
            evaluations[parentPID] = cached
            return (.unknown, nil, [:])
        }
        var current = parentPID
        var visited: Set<pid_t> = []
        var important: ProcessAncestryGate.Verdict?
        var persistentImportant: ProcessAncestryGate.Verdict?
        var protected: ProcessAncestryGate.Verdict?
        var userProtections: [String: String] = [:]
        func finish(_ verdict: ProcessAncestryGate.Verdict)
            -> (ProcessAncestryGate.Verdict, ProcessAncestryGate.Verdict?, [String: String]) {
            let effective = protected ?? verdict
            let cached = CachedEvaluation(verdict: effective, persistent: persistentImportant,
                userProtections: userProtections)
            evaluations[parentPID] = cached
            return (effective, persistentImportant, userProtections)
        }
        for _ in 0..<64 {
            if current == 1 || current == ownPID {
                return finish(important ?? .clear)
            }
            guard current > 1, visited.insert(current).inserted,
                  let node = nodes[current], node.identity.pid == current,
                  node.identity.startAbstime > 0, node.uid == getuid(),
                  node.path.hasPrefix("/"), !node.path.contains("\0") else {
                return finish(.unknown)
            }
            if node.protectedTask {
                persistentImportant = .protectedTask(node.name)
            } else if node.excludedFromAutomatic, persistentImportant == nil {
                persistentImportant = .importantTask(node.name)
            }
            if !protectedKeys.isEmpty {
                let keys = [node.path, AppResolver.appRoot(from: node.path), node.bundleIdentifier]
                for key in keys.compactMap({ $0 }) where protectedKeys.contains(key) {
                    userProtections[key] = node.name
                    protected = protected ?? .protectedTask(node.name)
                }
            }
            if node.protectedTask { protected = protected ?? .protectedTask(node.name) }
            if node.excludedFromAutomatic { important = important ?? .importantTask(node.name) }
            // Keep walking after the first protected parent. Another enabled
            // ancestor rule must survive removal of that first rule even if
            // the child is subsequently adopted by launchd.
            current = node.parentPID
        }
        return finish(.unknown)
    }
}
