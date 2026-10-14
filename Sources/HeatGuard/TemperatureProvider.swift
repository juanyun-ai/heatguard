import Foundation
@preconcurrency import Dispatch
import HeatGuardNative

/// Presentation-only band for the experimental CPU temperature reading. It
/// must not be treated as an action permission: duration, CPU, I/O, identity,
/// session and protection gates remain independent in AutomaticProtection.
enum TemperatureBand: String, Sendable {
    case normal
    case anomaly
    case enforceReference

    var title: String {
        switch self {
        case .normal: "硬件温度参考正常"
        case .anomaly: "硬件温度偏高"
        case .enforceReference: "硬件温度很高"
        }
    }

    var detail: String {
        switch self {
        case .normal: "低于 65°C 异常参考线。"
        case .anomaly: "已达到 65°C 异常参考线；需连续 5 分钟才形成异常观察。"
        case .enforceReference: "已达到 70°C 执行参考线；仍需连续 20 分钟、CPU/低 I/O 和全部保护门禁。"
        }
    }
}

struct TemperatureReading: Sendable {
    enum Source: String, Sendable {
        case appleSMC = "AppleSMC"
        case ioHID = "IOHID"
    }

    let celsius: Double
    let sensorCount: Int
    let source: Source
    let date: Date

    var band: TemperatureBand {
        if celsius >= 70 { return .enforceReference }
        if celsius >= 65 { return .anomaly }
        return .normal
    }

    /// Shared admission rule for asynchronous delivery and final execution.
    /// A failed/late sensor reply must not remain actionable until another
    /// process sample happens to notice it.
    func isUsable(at now: Date, maximumAge: TimeInterval = 90) -> Bool {
        let age = now.timeIntervalSince(date)
        return celsius.isFinite && celsius > 0 && celsius < 150
            && sensorCount > 0 && age.isFinite && age >= 0 && age <= maximumAge
    }
}

enum TemperatureProvider {
    // The native sensor API cannot be interrupted safely. Share one admission
    // gate for the entire process, not one gate per caller or sampling cycle.
    private static let reader = BoundedTemperatureReader(nativeRead: nativeRead)

    static func read() async -> TemperatureReading? {
        await reader.read()
    }

    private static let nativeRead: @Sendable () -> TemperatureReading? = {
        var sample = HGTemperatureSample()
        guard hg_read_cpu_temperature(&sample) == 1,
              sample.cpu_celsius.isFinite,
              sample.cpu_celsius > 0,
              sample.cpu_celsius < 150 else { return nil }
        let source: TemperatureReading.Source
        switch sample.backend {
        case HG_TEMP_APPLE_SMC: source = .appleSMC
        case HG_TEMP_IOHID: source = .ioHID
        default: return nil
        }
        return TemperatureReading(celsius: sample.cpu_celsius,
                                  sensorCount: Int(sample.sensor_count),
                                  source: source, date: Date())
    }
}

/// A timed-out caller does not imply that an uninterruptible native read ended.
/// Keep the flight occupied until the closure actually returns. While occupied,
/// additional callers receive nil immediately instead of queuing more work.
/// The injectable closure lets tests exercise a blocked native API safely.
final class BoundedTemperatureReader: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private let timeout: TimeInterval
    private let nativeRead: @Sendable () -> TemperatureReading?

    init(timeout: TimeInterval = 2, nativeRead: @escaping @Sendable () -> TemperatureReading?) {
        self.timeout = timeout.isFinite ? max(0.001, min(timeout, 60)) : 2
        self.nativeRead = nativeRead
    }

    func read() async -> TemperatureReading? {
        guard beginFlight() else { return nil }
        let deadline = DispatchTime.now() + timeout
        return await withCheckedContinuation { continuation in
            let completion = TemperatureContinuation(continuation, deadline: deadline)
            let timeoutWork = DispatchWorkItem { completion.resume(nil) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: timeoutWork)
            DispatchQueue.global(qos: .utility).async {
                let reading = self.nativeRead()
                // Only the actual native return releases admission. The timeout
                // callback never clears inFlight, and no result is cached.
                self.endFlight()
                timeoutWork.cancel()
                completion.resume(reading)
            }
        }
    }

    private func beginFlight() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    private func endFlight() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}

private final class TemperatureContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let deadline: DispatchTime
    private let continuation: CheckedContinuation<TemperatureReading?, Never>

    init(_ continuation: CheckedContinuation<TemperatureReading?, Never>, deadline: DispatchTime) {
        self.continuation = continuation
        self.deadline = deadline
    }

    func resume(_ value: TemperatureReading?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        // Do not let a delayed timeout callback turn a late native return into
        // fresh thermal evidence. DispatchTime is monotonic across clock edits.
        let timelyValue = DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds ? value : nil
        lock.unlock()
        continuation.resume(returning: timelyValue)
    }
}
