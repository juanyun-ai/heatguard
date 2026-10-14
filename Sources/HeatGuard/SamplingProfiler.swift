import AppKit
import Foundation

/// Explicit developer diagnostic, never started by resident monitoring. It
/// creates no MonitorModel or ActionExecutor, writes no settings/history and
/// reports aggregate timing only (no process names, paths or document data).
@MainActor
enum SamplingProfiler {
    static func run() async -> Int32 {
        _ = NSApplication.shared
        let worker = MonitoringWorker()
        var timings = SamplingTimingBuffer()
        let protectedKeys = Set(UserDefaults.standard.stringArray(forKey: "protectedBundleIDs") ?? [])
        var contextTotal = 0.0
        var workerTotal = 0.0
        var policyTotal = 0.0
        var policy = AutomaticProtectionEngine()
        // Profiling must never select the destructive policy, even though the
        // evidence engine itself has no dispatch capability. Keep this path
        // semantically advice-only and make the empty authorization explicit
        // so a future refactor cannot mistake it for an execution rehearsal.
        let policySettings = AutoProtectionSettings(mode: .advise)
        var latestProcesses: [AppProcess] = []
        let initialCPU = NativeSampler.process(pid: getpid())?.cpuTimeNanoseconds
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0...6 {
            if index > 0 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { print("profile=cancelled"); return 130 }
            }
            let contextStart = ProcessInfo.processInfo.systemUptime
            let context = AnalysisContextCapture.capture(protectedKeys: protectedKeys)
            let contextMS = (ProcessInfo.processInfo.systemUptime - contextStart) * 1000
            let result = await worker.sample(context: context, limited: [])
            // Measure only the evidence engine. Its returned decisions are
            // discarded; no MonitorModel, grants or action executor exists.
            let policyStart = ProcessInfo.processInfo.systemUptime
            _ = policy.observe(now: result.date, temperature: nil, processes: result.processes,
                settings: policySettings, isScanning: false, authorizedTargets: [])
            let policyMS = (ProcessInfo.processInfo.systemUptime - policyStart) * 1000
            // The cold first snapshot establishes deltas; report it separately.
            let phase = result.timings
            print(String(format: "profile_sample=%d valid_delta=%d processes=%d readable=%d context_ms=%.3f snapshot_ms=%.3f delta_ms=%.3f metadata_ms=%.3f analysis_ms=%.3f worker_ms=%.3f policy_ms=%.3f",
                index, result.cpu == nil ? 0 : 1, result.totalProcessCount, result.readableProcessCount,
                contextMS, phase.snapshotMilliseconds, phase.deltaMilliseconds,
                phase.metadataMilliseconds, phase.analysisMilliseconds, result.elapsedMilliseconds, policyMS))
            if index > 0, result.cpu != nil {
                latestProcesses = result.processes
                timings.append(phase)
                contextTotal += contextMS
                workerTotal += result.elapsedMilliseconds
                policyTotal += policyMS
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let finalCPU = NativeSampler.process(pid: getpid())?.cpuTimeNanoseconds
        let mean = timings.mean
        print(String(format: "profile_summary valid_samples=%d context_mean_ms=%.3f snapshot_mean_ms=%.3f delta_mean_ms=%.3f metadata_mean_ms=%.3f analysis_mean_ms=%.3f worker_mean_ms=%.3f policy_mean_ms=%.3f elapsed_seconds=%.3f",
            timings.count, contextTotal / Double(max(1, timings.count)), mean.snapshotMilliseconds,
            mean.deltaMilliseconds, mean.metadataMilliseconds, mean.analysisMilliseconds,
            workerTotal / Double(max(1, timings.count)), policyTotal / Double(max(1, timings.count)), elapsed))
        if let initialCPU, let finalCPU, finalCPU >= initialCPU {
            print(String(format: "profile_cpu_total_seconds=%.6f", Double(finalCPU - initialCPU) / 1e9))
        }
        // Same immutable frame and timestamp for A/B/A. This isolates pure
        // list selection, not SwiftUI rendering or whole-app energy use.
        let selectionDate = Date()
        for variant in ["legacy_a1", "current_b", "legacy_a2"] {
            let before = ProcessInfo.processInfo.systemUptime
            var checksum = 0
            for _ in 0..<40 {
                let selected = variant == "current_b"
                    ? TopProcessSelector.select(latestProcesses, ignoredUntil: [:], now: selectionDate)
                    : legacySelection(latestProcesses, now: selectionDate)
                checksum += selected.count
            }
            print(String(format: "profile_selection=%@ iterations=40 mean_ms=%.3f checksum=%d",
                variant, (ProcessInfo.processInfo.systemUptime - before) * 1000 / 40, checksum))
        }
        for label in ["cold", "warm"] {
            let beforeCPU = NativeSampler.process(pid: getpid())?.cpuTimeNanoseconds
            let temperatureStart = ProcessInfo.processInfo.systemUptime
            let reading = await TemperatureProvider.read()
            let wallMS = (ProcessInfo.processInfo.systemUptime - temperatureStart) * 1000
            let afterCPU = NativeSampler.process(pid: getpid())?.cpuTimeNanoseconds
            let cpuMS: Double? = beforeCPU.flatMap { before in
                afterCPU.flatMap { after in after >= before ? Double(after - before) / 1e6 : nil }
            }
            print("profile_temperature=\(label) available=\(reading != nil) wall_ms=\(String(format: "%.3f", wallMS)) cpu_ms=\(cpuMS.map { String(format: "%.3f", $0) } ?? "unknown")")
        }
        print("profile_scope=read_only_worker_context_evidence_policy_selection_temperature; policy_uses_advise_with_empty_authorized_targets_without_temperature_or_dispatch; selection_uses_same_frame_empty_ignore_table; excludes_model_apply_dashboard_rendering_and_history_IO; wall_time_is_not_CPU_percent")
        return timings.count == 6 ? 0 : 1
    }

    @inline(never)
    private static func legacySelection(_ processes: [AppProcess], now: Date) -> [AppProcess] {
        let ignoredUntil: [String: Date] = [:]
        return processes.filter { ignoredUntil[$0.groupKey, default: .distantPast] <= now }
            .filter { $0.cpuPercent >= 0.5 || $0.risk >= .elevated || $0.isSoftLimited || $0.wakeupsPerSecond >= 500 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
