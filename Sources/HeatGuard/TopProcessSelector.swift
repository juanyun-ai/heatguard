import Foundation

/// Pure display filtering, independent of action eligibility. A single time
/// snapshot makes an ignore deadline deterministic across one rendered list.
enum TopProcessSelector {
    static func select(_ processes: [AppProcess], ignoredUntil: [String: Date], now: Date) -> [AppProcess] {
        processes.filter {
            ($0.cpuPercent >= 0.5 || $0.risk >= .elevated || $0.isSoftLimited || $0.wakeupsPerSecond >= 500)
                && (ignoredUntil.isEmpty || ignoredUntil[$0.groupKey, default: .distantPast] <= now)
        }.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
