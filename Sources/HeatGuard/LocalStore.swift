import Foundation

struct SavedHistory: Codable, Sendable {
    var points: [HostPoint] = []
    var reports: [DiagnosticReport] = []
    var events: [ActivityEvent] = []
    var thermalExposure: [ThermalExposureDay] = []

    init(points: [HostPoint] = [], reports: [DiagnosticReport] = [],
         events: [ActivityEvent] = [], thermalExposure: [ThermalExposureDay] = []) {
        self.points = points
        self.reports = reports
        self.events = events
        self.thermalExposure = thermalExposure
    }

    private enum CodingKeys: String, CodingKey {
        case points, reports, events, thermalExposure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decodeIfPresent([HostPoint].self, forKey: .points) ?? []
        reports = try container.decodeIfPresent([DiagnosticReport].self, forKey: .reports) ?? []
        events = try container.decodeIfPresent([ActivityEvent].self, forKey: .events) ?? []
        // Older history-v2 files do not contain the ledger.
        thermalExposure = try container.decodeIfPresent([ThermalExposureDay].self, forKey: .thermalExposure) ?? []
    }
}

actor LocalStore {
    private let file: URL
    private(set) var recoveryIssue: String?
    private var writesBlocked = false
    init(file: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.file = file ?? base.appendingPathComponent("HeatGuard/history-v2.json")
    }
    func load() -> SavedHistory {
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedHistory() }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 4_000_000 else { throw CocoaError(.fileReadTooLarge) }
            return bounded(try JSONDecoder().decode(SavedHistory.self, from: Data(contentsOf: file)))
        } catch {
            // Never silently overwrite unreadable history. A single sibling
            // backup lets monitoring recover without losing the original.
            let backup = file.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: file, to: backup)
                recoveryIssue = "旧历史无法读取，已保留原始备份并开始新的记录。"
            } catch {
                writesBlocked = true
                recoveryIssue = "旧历史无法读取且备份失败；已暂停历史写入，实时监控仍可用。"
            }
            return SavedHistory()
        }
    }
    func save(_ value: SavedHistory) throws {
        guard !writesBlocked else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(bounded(value))
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func bounded(_ value: SavedHistory) -> SavedHistory {
        return SavedHistory(points: TrendBuffer.bounded(value.points),
                            reports: Array(value.reports.suffix(12)), events: Array(value.events.suffix(60)),
                            thermalExposure: ThermalExposureLedger.bounded(value.thermalExposure))
    }
}

enum ReportExporter {
    static func markdown(_ report: DiagnosticReport) -> String {
        var lines = ["# 温衡排查报告", "", "时间：\(report.date.formatted())", "观察时长：\(Int(report.duration)) 秒",
                     "系统热状态：\(report.thermal.title)", "观察期整机 CPU 均值：\(report.hostCPUPercent.percentText)", "",
                     report.summary, "", report.coverageNote, "", "## CPU 贡献者", ""]
        for process in report.candidates {
            let label = process.evidence.contains(where: { $0.contains("仅系统深扫快照") }) ? "系统快照 CPU" : "观察期平均 CPU"
            lines += ["### \(process.displayName)", "", "\(label)：\(process.cpuPercent.percentText)（100% 为一个逻辑核心）",
                      process.evidence.joined(separator: "；"), "建议：\(process.recommendation)", ""]
        }
        lines += ["报告仅保存在本地；未包含命令行参数、文件路径或窗口内容。", "高 CPU 是工作量证据，不足以单独证明应用空转。"]
        return lines.joined(separator: "\n")
    }
}

/// One peak per minute preserves short spikes without keeping 5-second UI
/// frames for an entire day. The chart explicitly describes this as peaks.
enum TrendBuffer {
    static func append(_ point: HostPoint, to points: inout [HostPoint]) {
        let minute = Int(point.date.timeIntervalSince1970 / 60)
        if let last = points.last, Int(last.date.timeIntervalSince1970 / 60) == minute {
            if point.cpuPercent >= last.cpuPercent { points[points.count - 1] = point }
        } else {
            points.append(point)
        }
        let cutoff = point.date.addingTimeInterval(-86_400)
        points.removeAll { $0.date < cutoff }
        if points.count > 1440 { points.removeFirst(points.count - 1440) }
    }
    static func bounded(_ points: [HostPoint], now: Date = Date()) -> [HostPoint] {
        let cutoff = now.addingTimeInterval(-86_400)
        var minutes: [Int: HostPoint] = [:]
        for point in points where point.date >= cutoff && point.date <= now.addingTimeInterval(60) {
            let key = Int(point.date.timeIntervalSince1970 / 60)
            if point.cpuPercent >= (minutes[key]?.cpuPercent ?? -1) { minutes[key] = point }
        }
        return Array(minutes.values.sorted { $0.date < $1.date }.suffix(1440))
    }
}
