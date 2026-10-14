import Foundation
@preconcurrency import Dispatch

/// Bounded, offline checks: the fake native read has a three-second safety
/// release and never touches SMC/IOHID, real application processes, or files.
enum TemperatureProviderTests {
    static func run() async -> [(name: String, passed: Bool)] {
        let probe = BlockingTemperatureReadProbe()
        let reader = BoundedTemperatureReader(timeout: 0.08, nativeRead: { probe.read() })
        defer { probe.release() }
        var results: [(name: String, passed: Bool)] = []

        let start = ProcessInfo.processInfo.systemUptime
        let first = await reader.read()
        let entered = probe.waitForFirstEntry()
        results.append(("原生温度读取阻塞时调用方有界超时",
                        entered && first == nil && ProcessInfo.processInfo.systemUptime - start < 1.5))

        // Simulate many sampling cycles and simultaneous request sources after
        // the first caller has timed out while its native closure is still busy.
        var allUnavailable = true
        for _ in 0..<6 {
            if await reader.read() != nil { allUnavailable = false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let concurrentUnavailable = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { await reader.read() == nil } }
            var unavailable = true
            for await value in group { unavailable = unavailable && value }
            return unavailable
        }
        let blocked = probe.snapshot()
        results.append(("连续超时及并发采样不重叠也不排队原生读取",
                        allUnavailable && concurrentUnavailable && blocked.calls == 1
                        && blocked.active == 1 && blocked.peak == 1))

        probe.release()
        // The native closure must really finish before the next reading can be
        // admitted. Use bounded retries to avoid depending on thread timing.
        var recovered: TemperatureReading?
        for _ in 0..<100 {
            recovered = await reader.read()
            if recovered != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        results.append(("原生读取真正结束后门禁恢复并取得新读数",
                        recovered?.celsius == 54 && recovered?.sensorCount == 2))

        let next = await reader.read()
        let finished = probe.snapshot()
        results.append(("超时晚结果不覆盖后续证据且没有遗留待执行队列",
                        first == nil && recovered?.celsius == 54 && next?.celsius == 54
                        && finished.calls == 3 && finished.active == 0 && finished.peak == 1))
        return results
    }
}

private final class BlockingTemperatureReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let enteredSignal = DispatchSemaphore(value: 0)
    private var calls = 0
    private var active = 0
    private var peak = 0

    func read() -> TemperatureReading? {
        lock.lock()
        calls += 1
        let invocation = calls
        active += 1
        peak = max(peak, active)
        lock.unlock()
        if invocation == 1 { enteredSignal.signal() }
        // A finite wait is important even if a failed test never signals.
        if invocation == 1 { _ = releaseSignal.wait(timeout: .now() + 3) }
        lock.lock()
        active -= 1
        lock.unlock()
        return TemperatureReading(celsius: invocation == 1 ? 99 : 54,
                                  sensorCount: invocation == 1 ? 1 : 2,
                                  source: .appleSMC, date: Date())
    }

    func release() { releaseSignal.signal() }

    func waitForFirstEntry() -> Bool {
        enteredSignal.wait(timeout: .now() + 1) == .success
    }

    func snapshot() -> (calls: Int, active: Int, peak: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, active, peak)
    }
}
