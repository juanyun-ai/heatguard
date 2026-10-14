import Foundation

/// Real production analysis -> policy, but entirely synthetic observations.
/// No native sampling, signal, settings write, app registration or UI.
enum ExplicitConsentRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let scenarios: [(String, Bool, Bool, Bool, Bool, Int?)] = [
            ("曾在前台使用的未知计算任务没有授权仍只提醒", true, false, false, false, nil),
            ("旧设置关闭前台历史限制也不能绕过明确授权", true, false, false, true, nil),
            ("曾在前台使用且明确授权的任务完整保护期后仍能自动处理", true, true, false, false, 3_060),
            ("纯后台明确授权仍能经过默认二十分钟和倒计时自动处理", false, true, false, false, 1_290),
            ("明确授权不能覆盖用户保护名单", true, true, true, false, nil)
        ]
        return scenarios.map { name, previouslyForeground, authorized, protected, legacy, expectedEnforce in
            var analyzer = AnalysisEngine()
            var engine = AutomaticProtectionEngine()
            let identity = ProcessIdentity(pid: 2_000_001, startAbstime: 123)
            let metadata = AppMetadata(displayName: "Caldera synthetic computation",
                bundleIdentifier: "review.caldera", bundleRoot: "/Applications/Caldera.app")
            let start = Date(timeIntervalSince1970: 800_000)
            let settings: AutoProtectionSettings
            if legacy {
                let data = Data(#"{"mode":"enforce","requireRecentForegroundHistory":false}"#.utf8)
                guard let decoded = try? JSONDecoder().decode(AutoProtectionSettings.self, from: data) else {
                    return (name, false)
                }
                settings = decoded
            } else {
                settings = AutoProtectionSettings(mode: .enforce)
            }
            var grants: Set<AutomaticTerminationGrant> = []
            var firstCountdown: Int?
            var firstEnforce: Int?
            var positiveAuthority = false
            for seconds in stride(from: 0, through: 3_120, by: 30) {
                let foreground = seconds == 0 && previouslyForeground
                let delta = ProcessDelta(identity: identity, parentPID: 1, uid: getuid(), name: "Caldera",
                    path: "/Applications/Caldera.app/Contents/MacOS/Caldera",
                    cpuPercent: foreground ? 5 : 120, wakeupsPerSecond: 10,
                    // Explicit consent binds the exact running identity, but
                    // it does not turn an actively writing task into an idle
                    // one. Keep this fixture CPU-bound and low-I/O so the
                    // scenario tests the intended automatic path.
                    diskBytesPerSecond: 0, residentBytes: 100 * 1_024 * 1_024,
                    sampleDuration: 30, wakeupsAvailable: true, diskAvailable: true)
                let context = AnalysisContext(foregroundPID: foreground ? identity.pid : nil,
                    metadata: [identity: metadata], protectedBundleIDs: protected ? ["review.caldera"] : [],
                    mainApplicationPIDs: [identity.pid])
                let now = start.addingTimeInterval(Double(seconds))
                guard let row = analyzer.analyze(deltas: [delta], at: now, thermal: .nominal,
                    limited: [], ownPID: getpid(), context: context).first else { return (name, false) }
                if seconds == 0 && authorized {
                    guard let grant = AutomaticTerminationGrant(process: row) else { return (name, false) }
                    // Fixed one-task fixture permission. Never re-grant on later frames.
                    grants = [grant]
                }
                let decision = engine.observe(now: now, temperature: 75, temperatureDate: now,
                    processes: [row], settings: settings, isScanning: false, authorizedTargets: grants)
                positiveAuthority = engine.hasAutomaticAuthority(for: row, authorizedTargets: grants)
                if decision.kind == .countdown && firstCountdown == nil { firstCountdown = seconds }
                if decision.kind == .enforce && firstEnforce == nil { firstEnforce = seconds }
            }
            let timingMatches = expectedEnforce.map { firstCountdown == $0 - 30 && firstEnforce == $0 }
                ?? (firstCountdown == nil && firstEnforce == nil)
            return (name, positiveAuthority == authorized && timingMatches)
        }
    }
}
