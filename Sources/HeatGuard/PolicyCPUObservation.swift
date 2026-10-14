import Foundation

/// Small, memory-only feedback for an explicit scheduling action. Reuses
/// existing CPU intervals, without timers, subprocesses or persistent samples.
struct PolicyCPUObservation: Sendable {
    let identity: ProcessIdentity
    let memberIdentities: Set<ProcessIdentity>
    let appliedIdentities: Set<ProcessIdentity>
    let path: String
    let executablePath: String?
    private(set) var beforeCPU: Double?
    private(set) var beforeTemperatureCelsius: Double?
    private(set) var observedSeconds: TimeInterval = 0
    private var weightedCPU: Double = 0
    private var weightedTemperature: Double = 0
    private var observedTemperatureSeconds: TimeInterval = 0
    private var earliestIntervalStart: Date
    private var lastIntervalEnd: Date?

    init?(process: AppProcess, sampleDate: Date?, sampleTemperatureCelsius: Double? = nil,
          sampleTemperatureDate: Date? = nil, applied: Set<ProcessIdentity>, startedAt: Date) {
        let members = Set(process.memberIdentities)
        guard !members.isEmpty, !applied.isEmpty, applied.isSubset(of: members),
              process.cpuPercent.isFinite, process.cpuPercent >= 0 else { return nil }
        identity = process.id
        memberIdentities = members
        appliedIdentities = applied
        path = process.path
        executablePath = process.executablePath
        earliestIntervalStart = startedAt
        beforeTemperatureCelsius = nil
        if let sampleDate, (0...90).contains(startedAt.timeIntervalSince(sampleDate)) {
            beforeCPU = process.cpuPercent
        }
        if let sampleTemperatureCelsius, sampleTemperatureCelsius.isFinite,
           (0..<150).contains(sampleTemperatureCelsius),
           let sampleTemperatureDate,
           (0...90).contains(startedAt.timeIntervalSince(sampleTemperatureDate)) {
            beforeTemperatureCelsius = sampleTemperatureCelsius
        }
    }

    var averageCPU: Double? { observedSeconds > 0 ? weightedCPU / observedSeconds : nil }
    var averageTemperatureCelsius: Double? {
        observedTemperatureSeconds > 0 ? weightedTemperature / observedTemperatureSeconds : nil
    }
    var isComplete: Bool { observedSeconds >= 60 }
    var remainsHigh: Bool { isComplete && (averageCPU ?? 0) >= 80 }

    /// A compact, user-facing progress indicator for the one-minute feedback
    /// window. It makes the reversible action observable immediately instead
    /// of leaving the user with a static "waiting" sentence until completion.
    var progressSummary: String {
        let observed = min(60, max(0, Int(observedSeconds.rounded(.down))))
        if isComplete { return "观察窗口已完成 · " + String(observed) + "/60 秒" }
        let remaining = max(0, 60 - observed)
        return "正在观察处理后状态 · " + String(observed) + "/60 秒 · 还需约 " + String(remaining) + " 秒"
    }

    var progressFraction: Double {
        min(1, max(0, observedSeconds / 60))
    }

    /// Directional feedback helps the user decide whether the reversible
    /// scheduling hint was observable. It is not a CPU cap or a causal claim.
    private var cpuDelta: Double? {
        guard isComplete, let beforeCPU, let averageCPU else { return nil }
        return averageCPU - beforeCPU
    }

    private var temperatureDelta: Double? {
        guard observedTemperatureSeconds >= 60,
              let beforeTemperatureCelsius,
              let averageTemperatureCelsius else { return nil }
        return averageTemperatureCelsius - beforeTemperatureCelsius
    }

    func matches(_ process: AppProcess) -> Bool {
        identity == process.id && memberIdentities == Set(process.memberIdentities)
            && path == process.path && executablePath == process.executablePath
    }

    mutating func invalidate(at date: Date) {
        beforeCPU = nil
        beforeTemperatureCelsius = nil
        observedSeconds = 0
        weightedCPU = 0
        weightedTemperature = 0
        observedTemperatureSeconds = 0
        earliestIntervalStart = date
        lastIntervalEnd = nil
    }

    /// A frame straddling the action includes pre-action CPU and must not be
    /// presented as its effect. Only full, contiguous post-action frames count.
    mutating func append(_ process: AppProcess, from: Date, to: Date,
                         temperatureCelsius: Double? = nil,
                         temperatureDate: Date? = nil) {
        guard matches(process), process.cpuPercent.isFinite, process.cpuPercent >= 0 else {
            invalidate(at: to)
            return
        }
        guard !isComplete else { return }
        let seconds = to.timeIntervalSince(from)
        guard seconds > 0, seconds < 90,
              lastIntervalEnd == nil || lastIntervalEnd == from else {
            invalidate(at: to)
            return
        }
        guard from >= earliestIntervalStart else { return }
        observedSeconds += seconds
        weightedCPU += process.cpuPercent * seconds
        if let temperatureCelsius, temperatureCelsius.isFinite,
           (0..<150).contains(temperatureCelsius),
           let temperatureDate,
           (0...90).contains(to.timeIntervalSince(temperatureDate)) {
            weightedTemperature += temperatureCelsius * seconds
            observedTemperatureSeconds += seconds
        }
        lastIntervalEnd = to
    }

    var summary: String {
        let before = beforeCPU.map { "处理前最近采样 \($0.percentText)" } ?? "处理前读数不可用"
        let after: String
        if let averageCPU {
            after = "处理后 \(Int(observedSeconds)) 秒均值 \(averageCPU.percentText)"
        } else {
            after = "等待处理后的完整采样窗口"
        }
        let effect: String
        if let cpuDelta {
            if abs(cpuDelta) < 5 {
                effect = "变化不足 5 个百分点"
            } else if cpuDelta < 0 {
                effect = String(format: "下降 %.1f 个百分点", abs(cpuDelta))
            } else {
                effect = String(format: "上升 %.1f 个百分点", cpuDelta)
            }
        } else {
            effect = "暂不能比较"
        }
        let scope = memberIdentities.count > 1
            ? "（整体应用，已降低 \(appliedIdentities.count)/\(memberIdentities.count) 个进程的调度优先级）" : ""
        let temperature: String
        if let temperatureDelta {
            let before = String(format: "%.1f°C", beforeTemperatureCelsius ?? 0)
            let after = String(format: "%.1f°C", averageTemperatureCelsius ?? 0)
            let direction = abs(temperatureDelta) < 0.5
                ? "变化不足 0.5°C"
                : (temperatureDelta < 0
                    ? String(format: "下降 %.1f°C", abs(temperatureDelta))
                    : String(format: "上升 %.1f°C", temperatureDelta))
            temperature = "温度 \(before) → \(after) · \(direction)"
        } else {
            temperature = "温度暂不能比较"
        }
        return before + " → " + after + " · " + effect + " · " + temperature + scope
    }

    var explanation: String {
        if !isComplete { return "正在利用常驻采样观察约 1 分钟；尚不足以判断变化。" }
        if remainsHigh {
            return "处理后仍高占用；CPU 对比不能单独证明调度效果或是否降温。请先核对任务是否有用，确认可中断时再使用红色“强制结束”。"
        }
        guard let cpuDelta else {
            return "处理后观察窗口已完成，但处理前读数不可用，暂不能比较变化。降低调度优先级不是 CPU 硬限速，也不能据此判断是否降温。"
        }
        if cpuDelta >= 5 {
            return "观察到 CPU 升高，但这可能来自任务自身阶段变化，不能据此判断调度是否生效或温度变化。请先核对任务是否有用，再决定是否需要手动处理。"
        }
        if cpuDelta <= -5 {
            return "观察到 CPU 有所下降，但这可能来自任务自身阶段变化；降低调度优先级不是 CPU 硬限速，也不保证温度下降。"
        }
        return "处理后观察窗口已完成，CPU 基本持平。降低调度优先级不是 CPU 硬限速；确认可中断时可使用红色“强制结束”。"
    }
}
