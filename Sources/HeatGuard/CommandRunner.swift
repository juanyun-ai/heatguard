import Foundation
import Darwin

struct CommandOutput: Sendable {
    let status: Int32
    let output: Data
    let error: String
    var succeeded: Bool { status == 0 }
}

/// Used only for our own short-lived top/taskpolicy subprocesses, never for
/// signaling a monitored application. Output is drained concurrently and capped.
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 5) async -> CommandOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSync(executable, arguments, timeout: timeout))
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], timeout: Double = 5) -> CommandOutput {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do { try task.run() }
        catch { return CommandOutput(status: -1, output: Data(), error: error.localizedDescription) }
        let capture = CommandCapture()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                capture.append(chunk)
            }
            drained.signal()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && task.isRunning {
            task.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut && task.isRunning {
                // Exact child that we created; this never targets an app under observation.
                Darwin.kill(task.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
        }
        _ = drained.wait(timeout: .now() + 0.5)
        let output = capture.value
        let status = timedOut || task.isRunning ? -2 : task.terminationStatus
        let error = timedOut ? "系统工具超时，已停止本次操作。" : String(data: output, encoding: .utf8) ?? ""
        return CommandOutput(status: status, output: output, error: error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read the scheduler fields once after an explicit policy action. Never
    /// call this from the periodic sampler: spawning `ps` every refresh would
    /// cost more CPU than the policy itself saves.
    static func schedulingObservation(pid: pid_t) async -> SchedulingObservation? {
        let result = await run("/bin/ps", ["-p", String(pid), "-o", "pri=,ni=,state="], timeout: 1)
        guard result.succeeded,
              let text = String(data: result.output, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let priority = Int(fields[0]), let nice = Int(fields[1]) else { continue }
            let native = NativeSampler.processScheduling(pid: pid)
            return SchedulingObservation(priority: priority, nice: nice, state: String(fields[2]),
                darwinPolicy: native?.policy, darwinPriority: native?.priority,
                darwinMaxPriority: native?.maxPriority,
                darwinThreadCount: native?.threadCount,
                darwinReadableThreads: native?.readableThreads,
                darwinBackgroundThreads: native?.backgroundThreads)
        }
        return nil
    }
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 262_144 - data.count)))
    }
    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
