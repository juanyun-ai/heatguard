import Foundation

/// Wall time owns evidence timestamps; monotonic time owns the real warning
/// window. Keeping both explicit lets integration tests drive the production
/// coordinator without heating the Mac or waiting twenty minutes per case.
struct AutomaticProtectionClock {
    var now: () -> Date
    var uptime: () -> TimeInterval

    static let system = AutomaticProtectionClock(
        now: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
}

/// Evidence-only policy engine. It never sends a signal or invokes a system
/// command; the UI model decides whether a returned `.enforce` decision may be
/// executed. Temperature is a supporting signal and must remain continuously
/// fresh; a stale sensor window cannot satisfy a rule.
struct AutomaticProtectionEngine: Sendable {
    private struct CountdownState: Sendable {
        let key: String
        let identities: Set<ProcessIdentity>
        let deadline: Date
    }

    private struct TemperaturePoint: Sendable {
        let date: Date
        let celsius: Double
    }

    private var temperatures: [TemperaturePoint] = []
    private var highSince: [String: Date] = [:]
    /// In the opt-in clear-idle scope, low I/O is itself continuous evidence.
    /// A single quiet frame must never authorize a kill; any I/O/wakeup spike
    /// restarts this timer while the ordinary high-CPU and temperature chains
    /// remain independently tracked.
    private var idleSince: [String: Date] = [:]
    // A diagnosis can cover protected apps and groups. Time spent under those
    // protections must never count toward automatic termination afterwards.
    private var enforcementSince: [String: Date] = [:]
    /// Continuous CPU evidence must belong to the same process identities.
    /// A bundle can restart while keeping its bundle key; carrying the old
    /// timer across that boundary could end a fresh instance without twenty
    /// minutes of evidence.
    private var highIdentities: [String: ForegroundIdentity] = [:]
    private var lastObservationDate: Date?
    private var recentForeground: [String: Date] = [:]
    /// Bind continuous load evidence to one task and executable. Foreground
    /// history protects recent work; it never grants termination permission.
    private struct ForegroundIdentity: Equatable, Sendable {
        let identities: Set<ProcessIdentity>
        let path: String
        let executablePath: String?

        init(_ process: AppProcess) {
            identities = Set(process.memberIdentities)
            path = process.path
            executablePath = process.executablePath
        }
    }
    private var countdown: CountdownState?
    private var cooldownUntil: [String: Date] = [:]
    private var suppressedKeys: Set<String> = []

    mutating func reset() {
        invalidateEvidence()
        recentForeground.removeAll(keepingCapacity: true)
        cooldownUntil.removeAll(keepingCapacity: true)
        suppressedKeys.removeAll(keepingCapacity: true)
    }

    /// Drop every continuous chain that could contribute to automatic action.
    /// A thermal read is a safety prerequisite, not just an explanatory label:
    /// if the sensor is absent or malformed, CPU/idle evidence must not survive
    /// the gap and become immediately actionable when a later read returns.
    private mutating func invalidateContinuousEvidence() {
        temperatures.removeAll(keepingCapacity: true)
        highSince.removeAll(keepingCapacity: true)
        idleSince.removeAll(keepingCapacity: true)
        enforcementSince.removeAll(keepingCapacity: true)
        highIdentities.removeAll(keepingCapacity: true)
        countdown = nil
    }

    /// A sampling fault invalidates the claim, not the user's cancellation,
    /// recent work, or an existing cooldown. Keep those safety decisions.
    mutating func invalidateEvidence() {
        invalidateContinuousEvidence()
        lastObservationDate = nil
    }

    mutating func cancelCountdown() {
        if let countdown { suppressedKeys.insert(countdown.key) }
        countdown = nil
    }

    /// An enforce decision is made before the action layer performs its final
    /// identity check. If that check rejects the action (or the OS refuses the
    /// signal), discard the pending cooldown and continuous evidence so a
    /// later, genuinely continuous incident can be evaluated from zero.
    mutating func abortEnforcement(for process: AppProcess) {
        let key = process.groupKey
        cooldownUntil.removeValue(forKey: key)
        highSince.removeValue(forKey: key)
        idleSince.removeValue(forKey: key)
        enforcementSince.removeValue(forKey: key)
        highIdentities.removeValue(forKey: key)
        if countdown?.key == key { countdown = nil }
    }

    /// Workspace activation notifications fill the gaps between low-frequency
    /// samples. The caller must validate this event against the current native
    /// identity/executable before recording it. Only this target loses its CPU
    /// timer; unrelated candidates and temperature continuity remain intact.
    mutating func recordForegroundUse(_ process: AppProcess, at date: Date) {
        let key = process.groupKey
        recentForeground[key] = date
        highSince.removeValue(forKey: key)
        idleSince.removeValue(forKey: key)
        enforcementSince.removeValue(forKey: key)
        highIdentities.removeValue(forKey: key)
        if countdown?.key == key { countdown = nil }
    }

    /// Explicit consent check for both policy evaluation and the action layer's
    /// last-moment revalidation. This is not an execution permission by itself:
    /// foreground/recent-use, protection, exclusions, temperature, duration,
    /// freshness, and countdown checks must still independently succeed.
    func hasAutomaticAuthority(for process: AppProcess,
                               authorizedTargets: Set<AutomaticTerminationGrant> = []) -> Bool {
        guard let identity = AutomaticTerminationGrant(process: process) else { return false }
        return authorizedTargets.contains(identity)
    }

    /// Exposes the current evidence ledger without creating a new observation
    /// or changing any timer. UI uses this to explain why a target is still
    /// only advice, while the decision path remains the sole authority.
    func evidence(for process: AppProcess, now: Date, settings: AutoProtectionSettings,
                  authorizedTargets: Set<AutomaticTerminationGrant> = []) -> AutomaticEvidenceProgress? {
        guard settings.isSane else { return nil }
        let key = process.groupKey
        let temperature65 = continuousTemperatureDuration(now: now,
            threshold: settings.anomalyTemperatureCelsius)
        let temperature70 = continuousTemperatureDuration(now: now,
            threshold: settings.enforceTemperatureCelsius)
        let temperatureFresh = temperatures.last.map {
            let age = now.timeIntervalSince($0.date)
            return age >= 0 && age <= 90
        } ?? false
        let highDuration = temperatureFresh
            ? (highSince[key].map { max(0, now.timeIntervalSince($0)) } ?? 0) : 0
        let idleDuration = temperatureFresh
            ? (idleSince[key].map { max(0, now.timeIntervalSince($0)) } ?? 0) : 0
        let recentlyUsed = recentForeground[key].map {
            now.timeIntervalSince($0) <= settings.recentForegroundGrace
        } ?? false
        let explicitAuthority = hasAutomaticAuthority(for: process, authorizedTargets: authorizedTargets)
        let blocked = temperatureFresh
            ? (automaticSafetyBlockReason(for: process, recentlyUsed: recentlyUsed)
                ?? automaticAuthorityBlockReason(for: process, idleDuration: idleDuration,
                                                 explicitAuthority: explicitAuthority, settings: settings))
            : "温度参考不可用或已过期，自动保护暂停。"
        let relevant = process.cpuPercent >= settings.minimumCPUPercent
            || highDuration > 0 || idleDuration > 0
        return AutomaticEvidenceProgress(highCPUDuration: highDuration,
            idleDuration: idleDuration,
            anomalyTemperatureDuration: temperature65,
            enforceTemperatureDuration: temperature70,
            anomalyDuration: settings.anomalyDuration,
            enforceDuration: settings.enforceDuration,
            anomalyTemperatureCelsius: settings.anomalyTemperatureCelsius,
            enforceTemperatureCelsius: settings.enforceTemperatureCelsius,
            minimumCPUPercent: settings.minimumCPUPercent,
            blockedReason: blocked,
            isRelevant: relevant)
    }

    mutating func observe(now: Date, temperature: Double?, temperatureDate: Date? = nil,
                          processes: [AppProcess], settings: AutoProtectionSettings,
                          isScanning: Bool,
                          authorizedTargets: Set<AutomaticTerminationGrant> = []) -> AutoProtectionDecision {
        // A stalled sampler, event-loop pause, or clock reversal invalidates
        // continuous CPU evidence just as a missing process frame does. The
        // monitor normally samples well within this bound; this guard prevents
        // a delayed frame from turning an old burst into a 20-minute claim.
        if let previous = lastObservationDate {
            let gap = now.timeIntervalSince(previous)
            if gap <= 0 || gap > 90 {
                invalidateContinuousEvidence()
                // A wall-clock reversal or a long sampler/sleep gap also
                // invalidates temperature continuity. Keeping the old points
                // around would make a future sample look adjacent to a
                // pre-sleep/pre-clock-change reading.
            }
        }
        lastObservationDate = now
        temperatures.removeAll { now.timeIntervalSince($0.date) > 7_200 }
        if let temperature, temperature.isFinite, temperature > 0, temperature < 150 {
            // The monitor passes the sensor's acquisition timestamp. Without
            // it, every process sample would duplicate the last hardware read
            // and make an unchanged/stale temperature look continuously fresh.
            let sampleDate = temperatureDate ?? now
            let clockSkew = sampleDate.timeIntervalSince(now)
            // Temperature readings are acquired asynchronously. A tiny future
            // skew is harmless, but a future timestamp means the wall clock
            // moved backwards (or a producer returned corrupt metadata). Do
            // not retain it as evidence and clear the prior chain.
            if clockSkew > 5 {
                invalidateContinuousEvidence()
            } else if let previous = temperatures.last, sampleDate < previous.date {
                // Out-of-order readings cannot form a continuous interval.
                temperatures.removeAll(keepingCapacity: true)
                temperatures.append(TemperaturePoint(date: sampleDate, celsius: temperature))
            } else if temperatures.last?.date != sampleDate {
                temperatures.append(TemperaturePoint(date: sampleDate, celsius: temperature))
            }
        } else {
            // A missing/invalid thermal read is a fail-closed sampling fault.
            // Do not carry old CPU or low-I/O evidence through it.
            invalidateContinuousEvidence()
        }
        let thermalEvidenceFresh = temperatures.last.map {
            let age = now.timeIntervalSince($0.date)
            return age >= 0 && age <= 90
        } ?? false
        if !thermalEvidenceFresh {
            // Do not let the process loop start a new CPU/idle interval while
            // the thermal prerequisite is unavailable or stale.
            highSince.removeAll(keepingCapacity: true)
            idleSince.removeAll(keepingCapacity: true)
            enforcementSince.removeAll(keepingCapacity: true)
            highIdentities.removeAll(keepingCapacity: true)
            countdown = nil
        }

        // Derive each immutable grouping key once per frame. Reusing within
        // this call cannot carry a key across an exec, restart or new frame.
        let keyedProcesses = processes.map { (key: $0.groupKey, process: $0) }
        let currentKeys = Set(keyedProcesses.map(\.key))
        // A missing frame is not continuous evidence. The next observation
        // must restart the timer instead of inheriting a gap of up to two
        // minutes, which could otherwise satisfy the 20-minute kill rule.
        highSince = highSince.filter { currentKeys.contains($0.key) }
        idleSince = idleSince.filter { currentKeys.contains($0.key) }
        enforcementSince = enforcementSince.filter { currentKeys.contains($0.key) }
        highIdentities = highIdentities.filter { currentKeys.contains($0.key) }
        recentForeground = recentForeground.filter { now.timeIntervalSince($0.value) < settings.recentForegroundGrace + 120 }

        typealias Candidate = (process: AppProcess, duration: TimeInterval, score: Double,
                               enforcementDuration: TimeInterval, blockedReason: String?,
                               idleReady: Bool)
        var candidates: [Candidate] = []
        cooldownUntil = cooldownUntil.filter { $0.value > now }
        // Missing evidence is not proof of cooling. Only an observed fresh
        // lower reading can release a user's cancellation for this episode.
        if let latest = temperatures.last, latest.date <= now,
           now.timeIntervalSince(latest.date) <= 90,
           latest.celsius < settings.enforceTemperatureCelsius {
            suppressedKeys.removeAll(keepingCapacity: true)
        }
        for (key, process) in keyedProcesses {
            if process.isForeground {
                recordForegroundUse(process, at: now)
            }
            let recentlyUsed = recentForeground[key].map { now.timeIntervalSince($0) <= settings.recentForegroundGrace } ?? false
            // Diagnosis is evidence-only. A browser, project, protected app or
            // application group can explain heat without becoming safe to end.
            let hasLoadEvidence = process.isBackground && !process.isForeground
                && !process.memberIdentities.isEmpty
                && process.memberIdentities.allSatisfy { $0.startAbstime > 0 }
                && process.cpuPercent.isFinite && process.cpuPercent >= settings.minimumCPUPercent
            guard hasLoadEvidence else {
                highSince.removeValue(forKey: key)
                idleSince.removeValue(forKey: key)
                enforcementSince.removeValue(forKey: key)
                highIdentities.removeValue(forKey: key)
                if countdown?.key == key { countdown = nil }
                continue
            }
            guard thermalEvidenceFresh else {
                candidates.append((process, 0, severityScore(for: process, duration: 0), 0,
                                   "温度参考不可用或已过期，自动保护暂停。", false))
                continue
            }
            let evidenceIdentity = ForegroundIdentity(process)
            // Do not accumulate across an exec/restart or a changed helper
            // membership under the same bundle identifier.
            if highIdentities[key] != evidenceIdentity {
                highIdentities[key] = evidenceIdentity
                highSince[key] = now
                idleSince.removeValue(forKey: key)
                enforcementSince.removeValue(forKey: key)
                if countdown?.key == key { countdown = nil }
            }
            let since = highSince[key] ?? now
            highSince[key] = since
            let duration = now.timeIntervalSince(since)
            let safetyBlock = automaticSafetyBlockReason(for: process, recentlyUsed: recentlyUsed)
            // Low activity while the task is protected is diagnosis, not
            // permission earned for later. Start a new full idle interval
            // only after recent use, active scheduling and other guards end.
            if safetyBlock == nil && ActivitySignature.lowIOHighCPU(cpuPercent: process.cpuPercent,
                                             diskBytesPerSecond: process.diskBytesPerSecond,
                                             wakeupsPerSecond: process.wakeupsPerSecond,
                                             diskAvailable: process.diskAvailable,
                                             wakeupsAvailable: process.wakeupsAvailable) {
                idleSince[key] = idleSince[key] ?? now
            } else {
                idleSince.removeValue(forKey: key)
            }
            let idleDuration = idleSince[key].map { max(0, now.timeIntervalSince($0)) } ?? 0
            let score = severityScore(for: process, duration: duration)
            let explicitAuthority = hasAutomaticAuthority(for: process, authorizedTargets: authorizedTargets)
            // An explicit per-run grant answers "may this identity ever be
            // considered?"; it must not turn an active I/O job into an idle
            // job. Every automatic path therefore needs the same continuous
            // low-I/O evidence before it can become enforceable.
            let idleReady = idleDuration >= settings.enforceDuration
            let blockedReason = safetyBlock ?? automaticAuthorityBlockReason(for: process,
                idleDuration: idleDuration, explicitAuthority: explicitAuthority,
                settings: settings)
            if blockedReason == nil {
                // Low-I/O evidence is itself the automatic authority window;
                // do not add a second hidden 20-minute wait after it is proven.
                enforcementSince[key] = now.addingTimeInterval(-idleDuration)
            } else {
                enforcementSince.removeValue(forKey: key)
                if countdown?.key == key { countdown = nil }
            }
            let automaticDuration = enforcementSince[key].map { now.timeIntervalSince($0) } ?? 0
            candidates.append((process, duration, score, automaticDuration, blockedReason,
                               idleReady))
        }

        func readiness(_ item: Candidate) -> Int {
            item.blockedReason == nil && item.enforcementDuration >= settings.enforceDuration
                ? 2 : (item.duration >= settings.anomalyDuration ? 1 : 0)
        }
        let available = candidates.filter {
            !suppressedKeys.contains($0.process.groupKey) && cooldownUntil[$0.process.groupKey] == nil
        }.sorted {
            if readiness($0) != readiness($1) { return readiness($0) > readiness($1) }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.process.groupKey < $1.process.groupKey
        }
        // Once announced, retain the same still-eligible target for its entire
        // cancellation window. Fluctuating CPU rankings must not keep starting
        // new countdowns indefinitely or move the user's cancellation target.
        let inCountdown = countdown.flatMap { pending in
            available.first { $0.process.groupKey == pending.key
                && Set($0.process.memberIdentities) == pending.identities }
        }
        guard settings.isSane else {
            countdown = nil
            return AutoProtectionDecision(kind: .none, process: nil, reason: "自动保护设置不在安全范围内。")
        }
        let temp65 = continuousTemperatureDuration(now: now, threshold: settings.anomalyTemperatureCelsius)
        let temp70 = continuousTemperatureDuration(now: now, threshold: settings.enforceTemperatureCelsius)
        guard let candidate = inCountdown ?? available.first else {
            countdown = nil
            if settings.isSane, !candidates.isEmpty {
                return AutoProtectionDecision(kind: .blocked, process: nil,
                    reason: "当前合格目标均已取消本次处理或处于冷却期；不会重复结束。")
            }
            if temp65 >= settings.anomalyDuration {
                return AutoProtectionDecision(kind: .anomaly, process: nil,
                    reason: "硬件温度已连续达到 \(Int(settings.anomalyTemperatureCelsius))°C 异常参考线，但当前没有可核验的持续高 CPU 后台；不会自动结束。")
            }
            return AutoProtectionDecision(kind: .none, process: nil, reason: "没有持续高 CPU 的后台异常候选。")
        }
        let temperatureFresh = temperatures.last.map {
            let age = now.timeIntervalSince($0.date)
            return age >= 0 && age <= 90
        } ?? false
        guard temperatureFresh else {
            countdown = nil
            return AutoProtectionDecision(kind: .blocked, process: candidate.process,
                                          reason: "温度参考不可用或已过期，自动保护不会执行。")
        }
        let anomalyReady = temp65 >= settings.anomalyDuration && candidate.duration >= settings.anomalyDuration
        let enforceReady = temp70 >= settings.enforceDuration
            && candidate.enforcementDuration >= settings.enforceDuration

        guard anomalyReady else {
            countdown = nil
            return AutoProtectionDecision(kind: .none, process: nil, reason: "温度或后台 CPU 的连续证据尚不足。")
        }

        if let blockedReason = candidate.blockedReason {
            countdown = nil
            return AutoProtectionDecision(kind: .anomaly, process: candidate.process,
                reason: "持续高温和后台高 CPU 已达到异常条件；" + blockedReason)
        }

        if !enforceReady || settings.mode != .enforce || isScanning {
            countdown = nil
            return AutoProtectionDecision(kind: .anomaly, process: candidate.process,
                                          reason: "已连续满足异常观察条件；不会自动结束当前目标。")
        }

        // The normal path deliberately gives the user a monotonic 30-second
        // escape hatch.  Immediate mode is a separately confirmed,
        // high-risk choice and is never inferred from a legacy preference.
        // Keep the same engine evidence and require an automatic clear-idle
        // scope; an explicit-grant-only policy must continue to use the
        // cancellable path even if a preference is hand-edited.
        if settings.automaticTerminationTiming.isImmediate {
            guard settings.automaticTerminationScope.allowsClearIdle,
                  candidate.idleReady else {
                countdown = nil
                return AutoProtectionDecision(kind: .anomaly, process: candidate.process,
                    reason: "直接自动结束只对已确认的连续低 I/O 空转开放；当前目标只提醒。")
            }
            countdown = nil
            cooldownUntil[candidate.process.groupKey] = now.addingTimeInterval(settings.cooldown)
            return AutoProtectionDecision(kind: .enforce, process: candidate.process,
                reason: "温度和后台高 CPU 已持续足够长时间，且低 I/O 空转证据已连续成立。直接自动结束已启用。")
        }

        let candidateIdentities = Set(candidate.process.memberIdentities)
        if let countdown, countdown.key == candidate.process.groupKey,
           countdown.identities == candidateIdentities {
            if now >= countdown.deadline {
                self.countdown = nil
                cooldownUntil[candidate.process.groupKey] = now.addingTimeInterval(settings.cooldown)
                let evidence = candidate.idleReady
                    ? "温度和后台高 CPU 已持续足够长时间，且低 I/O 空转证据已连续成立。"
                    : "温度已连续超过阈值且后台高 CPU 已持续足够长时间。"
                return AutoProtectionDecision(kind: .enforce, process: candidate.process,
                                              reason: evidence)
            }
            return AutoProtectionDecision(kind: .countdown, process: candidate.process,
                                          reason: "自动保护倒计时还剩 \(max(0, Int(ceil(countdown.deadline.timeIntervalSince(now))))) 秒。")
        }

        self.countdown = CountdownState(key: candidate.process.groupKey,
                                        identities: candidateIdentities,
                                        deadline: now.addingTimeInterval(30))
        let authority = candidate.idleReady
            ? "已连续确认低 I/O 空转，"
            : "已满足自动保护条件，"
        return AutoProtectionDecision(kind: .countdown, process: candidate.process,
                                      reason: authority + "先给你 30 秒取消机会。")
    }

    private func automaticSafetyBlockReason(for process: AppProcess, recentlyUsed: Bool) -> String? {
        if process.isSystem || process.uid != getuid() { return "系统或其他用户的任务只提醒，不自动结束。" }
        if process.isProtected { return "该应用受保护，只提醒；请在应用内核对任务。" }
        if let reason = process.automaticContextBlockReason { return reason }
        if recentlyUsed { return "该应用仍在最近使用保护期内，只提醒；保护期结束后重新累计自动处理时长。" }
        if process.isSoftLimited { return "正在执行你选择的优先级调整，只提醒；可查看处理效果或手动处理。" }
        if process.memberIdentities.count != 1 { return "这是包含辅助进程的应用组，只提醒；请核对具体任务后手动处理。" }
        if LocalKnowledgeBase.isAutomaticProtectionExcluded(name: process.name, path: process.path,
                                                            bundleIdentifier: process.bundleIdentifier)
            || LocalKnowledgeBase.isAutomaticProtectionExcluded(name: process.name,
                path: process.executablePath ?? "", bundleIdentifier: process.bundleIdentifier) {
            return "这类浏览器、工程或沟通任务需要人工核对，只提醒，不自动结束。"
        }
        if process.risk < .elevated { return "负载已持续，但风险评估尚未允许自动结束；只提醒。" }
        guard AutomaticTerminationGrant(process: process) != nil else {
            return "缺少完整可核验的可执行文件身份，只提醒，不能自动结束。"
        }
        return nil
    }

    private func automaticAuthorityBlockReason(for process: AppProcess,
                                      idleDuration: TimeInterval,
                                      explicitAuthority: Bool,
                                      settings: AutoProtectionSettings) -> String? {
        if !explicitAuthority {
            guard settings.automaticTerminationScope.allowsClearIdle else {
                return "缺少本次运行授权，只提醒；前台使用记录不代表任务可结束，核对后可单独授权。"
            }
            if process.bundleIdentifier == nil {
                guard settings.automaticTerminationScope.allowsEphemeralCLI,
                      LocalKnowledgeBase.isEphemeralCommandLineTarget(
                        name: process.name, path: process.path,
                        bundleIdentifier: process.bundleIdentifier,
                        executablePath: process.executablePath) else {
                    return "这是无应用标识或非临时来源的命令行任务，只提醒；请核对项目后单独授权。"
                }
            }
        }
        guard idleDuration >= settings.enforceDuration else {
            return explicitAuthority
                ? "本次运行授权仍需连续确认足够长的低 I/O 空转，只提醒；活动任务不会自动结束。"
                : "尚未连续确认足够长的低 I/O 空转，只提醒；仍需核对任务是否有用。"
        }
        return nil
    }

    private func continuousTemperatureDuration(now: Date, threshold: Double) -> TimeInterval {
        guard let latest = temperatures.last, latest.celsius >= threshold,
              now.timeIntervalSince(latest.date) <= 90 else { return 0 }
        var start = latest.date
        for point in temperatures.dropLast().reversed() {
            guard point.celsius >= threshold,
                  start.timeIntervalSince(point.date) <= 90 else { break }
            start = point.date
        }
        return max(0, now.timeIntervalSince(start))
    }

    /// Prefer the target that contributes the most sustained heat pressure,
    /// while first preferring a target that has actually reached the full
    /// enforce duration. This avoids letting a newer, hotter process hide an
    /// older process that already satisfies the user's 20-minute rule.
    private func severityScore(for process: AppProcess, duration: TimeInterval) -> Double {
        let riskWeight = process.risk == .high ? 1.25 : 1.0
        let durationWeight = min(max(duration / 60, 1), 120)
        return process.cpuPercent * riskWeight + durationWeight
    }
}
