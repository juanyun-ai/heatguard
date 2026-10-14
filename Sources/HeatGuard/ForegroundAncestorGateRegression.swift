import Darwin

/// Pure ancestry-state tests. Every parent lookup is a local closure; no live
/// process is read or signaled. ActionSafety wiring is tested separately.
enum ForegroundAncestorGateRegression {
    static func results() -> [(name: String, passed: Bool)] {
        typealias State = ForegroundAncestorGate.State
        let foregroundPID: pid_t = 900
        let ownPID: pid_t = 901
        var results: [(name: String, passed: Bool)] = []

        func check(_ name: String, parent: pid_t, foreground: pid_t? = 900,
                   own: pid_t = 901, parents: [pid_t: pid_t] = [:],
                   expected: State, expectedLookups: [pid_t]) {
            var lookedUp: [pid_t] = []
            let actual = ForegroundAncestorGate.evaluate(parentPID: parent,
                foregroundPID: foreground, ownPID: own) { pid in
                    lookedUp.append(pid)
                    return parents[pid]
                }
            results.append(("前台祖先门禁：" + name,
                            actual == expected && lookedUp == expectedLookups))
        }

        check("没有前台 PID 保持原行为且不查询", parent: 200, foreground: nil,
              expected: .clear, expectedLookups: [])
        check("前台 PID 一保持原行为且不查询", parent: 200, foreground: 1,
              expected: .clear, expectedLookups: [])
        check("前台 PID 零保持原行为且不查询", parent: 200, foreground: 0,
              expected: .clear, expectedLookups: [])
        check("负前台 PID 保持原行为且不查询", parent: 200, foreground: -1,
              expected: .clear, expectedLookups: [])
        check("直接到 PID 一有明确非前台证据", parent: 1,
              expected: .clear, expectedLookups: [])
        check("自身私有 helper 终点不查询真实祖先", parent: ownPID,
              expected: .clear, expectedLookups: [])
        check("自身 PID 同时为前台时优先私有 helper 终点", parent: ownPID,
              foreground: ownPID, expected: .clear, expectedLookups: [])
        check("直接父进程就是前台立即阻挡", parent: foregroundPID,
              expected: .foreground, expectedLookups: [])
        check("多跳祖先抵达前台立即阻挡", parent: 200,
              parents: [200: 201, 201: foregroundPID], expected: .foreground,
              expectedLookups: [200, 201])
        check("完整可读父链抵达 PID 一才放行", parent: 200,
              parents: [200: 201, 201: 1], expected: .clear,
              expectedLookups: [200, 201])
        check("完整可读父链抵达自身私有 helper 终点", parent: 200,
              parents: [200: 201, 201: ownPID], expected: .clear,
              expectedLookups: [200, 201])
        check("首个祖先读取失败为未知", parent: 200,
              expected: .unknown, expectedLookups: [200])
        check("中间祖先读取失败为未知", parent: 200,
              parents: [200: 201], expected: .unknown, expectedLookups: [200, 201])
        check("父 PID 零为未知且不查询", parent: 0,
              expected: .unknown, expectedLookups: [])
        check("负父 PID 为未知且不查询", parent: -1,
              expected: .unknown, expectedLookups: [])
        check("链中返回零父 PID 为未知", parent: 200,
              parents: [200: 0], expected: .unknown, expectedLookups: [200])
        check("链中返回负父 PID 为未知", parent: 200,
              parents: [200: -1], expected: .unknown, expectedLookups: [200])
        check("自环为未知且不重复查询", parent: 200,
              parents: [200: 200], expected: .unknown, expectedLookups: [200])
        check("多节点环为未知且不重复查询", parent: 200,
              parents: [200: 201, 201: 202, 202: 200], expected: .unknown,
              expectedLookups: [200, 201, 202])

        // Sixty-three intermediate nodes plus the terminal PID are exactly
        // 64 examined nodes. The terminal does not require a native lookup.
        let intermediates = (0..<63).map { pid_t(1_000 + $0) }
        var chain: [pid_t: pid_t] = [:]
        for pair in zip(intermediates, intermediates.dropFirst()) { chain[pair.0] = pair.1 }
        chain[intermediates.last!] = 1
        check("第六十四个节点为 PID 一可确认放行", parent: intermediates[0],
              parents: chain, expected: .clear, expectedLookups: intermediates)
        chain[intermediates.last!] = foregroundPID
        check("第六十四个节点为前台仍然阻挡", parent: intermediates[0],
              parents: chain, expected: .foreground, expectedLookups: intermediates)
        chain[intermediates.last!] = ownPID
        check("第六十四个节点为自身 helper 可确认放行", parent: intermediates[0],
              parents: chain, expected: .clear, expectedLookups: intermediates)

        let sixtyFourth: pid_t = 1_063
        chain[intermediates.last!] = sixtyFourth
        chain[sixtyFourth] = 1
        check("第六十五个节点才出现终点仍保持未知", parent: intermediates[0],
              parents: chain, expected: .unknown, expectedLookups: intermediates + [sixtyFourth])

        var unboundedLookups = 0
        let capped = ForegroundAncestorGate.evaluate(parentPID: 2_000,
            foregroundPID: foregroundPID, ownPID: ownPID) { pid in
                unboundedLookups += 1
                return pid + 1
            }
        results.append(("前台祖先门禁：无限增长伪链最多查询六十四次",
                        capped == .unknown && unboundedLookups == 64))
        return results
    }
}
