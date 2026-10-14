import Darwin
import Foundation

/// Pure display-selection regressions. No process lookup, signal, preferences,
/// file write, or application registration. This is not action authorization.
enum TopProcessSelectorRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(1)
        let past = now.addingTimeInterval(-1)
        var results: [(name: String, passed: Bool)] = []

        func check(_ name: String, _ input: [AppProcess], ignored: [String: Date] = [:],
                   expected: [ProcessIdentity]) {
            let selected = TopProcessSelector.select(input, ignoredUntil: ignored, now: now)
            results.append(("显示筛选：" + name, selected.map(\.id) == expected))
        }

        check("空输入返回空列表", [], expected: [])

        let belowCPU = row(1, cpu: 0.499)
        let boundaryCPU = row(2, cpu: 0.5)
        let aboveCPU = row(3, cpu: 0.501)
        check("空忽略表保留 CPU 0.5 边界且按占用降序",
              [boundaryCPU, belowCPU, aboveCPU], expected: [aboveCPU.id, boundaryCPU.id])

        let normalRisk = row(4, cpu: 0, risk: .normal)
        let watchRisk = row(5, cpu: 0, risk: .watch)
        let elevatedRisk = row(6, cpu: 0.1, risk: .elevated)
        let highRisk = row(7, cpu: 0.2, risk: .high)
        check("低 CPU 仅 elevated 及以上风险可见",
              [normalRisk, watchRisk, elevatedRisk, highRisk], expected: [highRisk.id, elevatedRisk.id])

        let ordinaryIdle = row(8, cpu: 0)
        let softenedIdle = row(9, cpu: 0, softLimited: true)
        check("已调整调度的低负载目标仍可见", [ordinaryIdle, softenedIdle], expected: [softenedIdle.id])

        let belowWakeups = row(10, cpu: 0.1, wakeups: 499.999)
        let boundaryWakeups = row(11, cpu: 0.2, wakeups: 500)
        let aboveWakeups = row(12, cpu: 0.3, wakeups: 500.001)
        check("唤醒频率 500 边界可见",
              [boundaryWakeups, belowWakeups, aboveWakeups], expected: [aboveWakeups.id, boundaryWakeups.id])

        let ignored = row(13, cpu: 80)
        let visible = row(14, cpu: 40)
        check("未来忽略期限隐藏目标", [ignored, visible],
              ignored: [ignored.groupKey: future], expected: [visible.id])
        check("恰好到期立即恢复可见", [ignored, visible],
              ignored: [ignored.groupKey: now], expected: [ignored.id, visible.id])
        check("过去忽略期限恢复可见", [ignored, visible],
              ignored: [ignored.groupKey: past], expected: [ignored.id, visible.id])
        check("无关忽略键不隐藏任何候选", [ignored, visible],
              ignored: ["bundle:example.unrelated": future], expected: [ignored.id, visible.id])
        check("到期忽略不会让低负载普通任务凭空入选", [ordinaryIdle],
              ignored: [ordinaryIdle.groupKey: now], expected: [])

        let bundleMain = row(15, cpu: 25, bundle: "example.shared",
                             path: "/Applications/One.app/Contents/MacOS/main")
        let bundleHelper = row(16, cpu: 50, bundle: "example.shared",
                               path: "/Applications/Two.app/Contents/MacOS/helper")
        check("相同 bundle 的多行不在显示层擅自归并", [bundleMain, bundleHelper],
              expected: [bundleHelper.id, bundleMain.id])
        check("忽略同一 bundle 键同时隐藏对应成员", [bundleMain, bundleHelper, visible],
              ignored: [bundleMain.groupKey: future], expected: [visible.id])

        let rootMain = row(17, cpu: 25, path: "/Applications/NoBundle.app/Contents/MacOS/main")
        let rootHelper = row(18, cpu: 50, path: "/Applications/NoBundle.app/Contents/MacOS/helper")
        check("无 bundle 时应用根分组共享忽略键", [rootMain, rootHelper, visible],
              ignored: [rootMain.groupKey: future], expected: [visible.id])

        let standalone = row(19, cpu: 25, path: "/private/tmp/pure-worker")
        let otherStandalone = row(20, cpu: 50, path: "/private/tmp/pure-worker")
        check("同路径独立进程不会共享忽略权限", [standalone, otherStandalone],
              ignored: [standalone.groupKey: future], expected: [otherStandalone.id])
        let restarted = row(19, cpu: 50, start: 999, path: "/private/tmp/pure-worker")
        check("同 PID 新启动身份不继承旧忽略键", [standalone, restarted],
              ignored: [standalone.groupKey: future], expected: [restarted.id])

        // Compare complete Codable rows, not merely counts or membership.
        // The reference is the former two-filter algorithm with one frozen
        // instant; per-row wall-clock expiry drift is intentionally excluded.
        let fixtures = [belowCPU, boundaryCPU, aboveCPU, normalRisk, watchRisk, elevatedRisk,
                        highRisk, ordinaryIdle, softenedIdle, belowWakeups, boundaryWakeups,
                        aboveWakeups, ignored, visible, bundleMain, bundleHelper, rootMain,
                        rootHelper, standalone, otherStandalone, restarted]
        let masks: [[String: Date]] = [
            [:],
            ["bundle:example.unrelated": future],
            [ignored.groupKey: future, bundleMain.groupKey: now, rootMain.groupKey: past],
            [bundleMain.groupKey: future, rootMain.groupKey: future, standalone.groupKey: future],
            Dictionary(fixtures.map { ($0.groupKey, future) }, uniquingKeysWith: { _, last in last })
        ]
        let orders = [fixtures, Array(fixtures.reversed()), Array(fixtures.dropFirst(7)) + Array(fixtures.prefix(7))]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var equivalent = true
        for input in orders {
            for mask in masks {
                let expected = input.filter { mask[$0.groupKey, default: .distantPast] <= now }
                    .filter { $0.cpuPercent >= 0.5 || $0.risk >= .elevated || $0.isSoftLimited || $0.wakeupsPerSecond >= 500 }
                    .sorted { $0.cpuPercent > $1.cpuPercent }
                let actual = TopProcessSelector.select(input, ignoredUntil: mask, now: now)
                guard let expectedData = try? encoder.encode(expected),
                      let actualData = try? encoder.encode(actual) else {
                    equivalent = false
                    continue
                }
                equivalent = equivalent && expectedData == actualData
            }
        }
        results.append(("显示筛选：15 组排列及忽略组合与冻结时刻的旧算法完整输出一致", equivalent))
        return results
    }

    private static func row(_ pid: pid_t, cpu: Double, risk: RiskLevel = .normal,
                            softLimited: Bool = false, wakeups: Double = 0,
                            start: UInt64 = 100, bundle: String? = nil,
                            path: String = "/private/tmp/pure-worker") -> AppProcess {
        let identity = ProcessIdentity(pid: pid, startAbstime: start)
        return AppProcess(id: identity, memberIdentities: [identity], pid: pid, parentPID: 1,
            uid: getuid(), name: "pure-worker", displayName: "Pure display row \(pid)",
            bundleIdentifier: bundle, path: path, cpuPercent: cpu, wakeupsPerSecond: wakeups,
            diskBytesPerSecond: 0, residentBytes: 0, isForeground: false, isBackground: true,
            isSystem: false, isProtected: false, protectionReason: nil, isSoftLimited: softLimited,
            risk: risk, confidence: 1, evidence: [], recommendation: "pure display fixture",
            executablePath: path)
    }
}
