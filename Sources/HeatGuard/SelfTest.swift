import Foundation
import HeatGuardNative

enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        var executed = 0
        func check(_ name: String, failures: inout [String], operation: () -> Bool) {
            executed += 1
            if !operation() { failures.append(name) }
        }

        check("整机 CPU 百分比", failures: &failures) {
            let previous = HostTicks(user: 100, system: 50, idle: 850, nice: 0)
            let current = HostTicks(user: 160, system: 90, idle: 950, nice: 0)
            guard let value = DeltaCalculator.hostCPU(previous: previous, current: current) else { return false }
            return abs(value - 50) < 0.001
        }

        check("整机 CPU 缺失或无效不是零负载", failures: &failures) {
            let ticks = HostTicks(user: 100, system: 50, idle: 850, nice: 0)
            let backwards = HostTicks(user: 90, system: 40, idle: 800, nice: 0)
            let idle = HostTicks(user: 100, system: 50, idle: 950, nice: 0)
            return DeltaCalculator.hostCPU(previous: nil, current: ticks) == nil
                && DeltaCalculator.hostCPU(previous: ticks, current: nil) == nil
                && DeltaCalculator.hostCPU(previous: ticks, current: ticks) == nil
                && DeltaCalculator.hostCPU(previous: ticks, current: backwards) == nil
                && DeltaCalculator.hostCPU(previous: ticks, current: idle) == 0
        }

        check("隔离 profile 偏好只存在进程内", failures: &failures) {
            let preferences = InMemoryPreferences()
            preferences.set("quiet", forKey: "samplingMode")
            preferences.set(["com.example.protected"], forKey: "protectedBundleIDs")
            preferences.set(true, forKey: "notificationsEnabled")
            return preferences.string(forKey: "samplingMode") == "quiet"
                && preferences.stringArray(forKey: "protectedBundleIDs") == ["com.example.protected"]
                && preferences.object(forKey: "notificationsEnabled") as? Bool == true
        }

        check("严重热状态下隐藏采样不会自我加热", failures: &failures) {
            SamplingCadencePolicy.interval(mode: .adaptive, automaticMode: .enforce,
                thermal: .serious, active: false, scanning: false, countdown: false) == 30
                && SamplingCadencePolicy.interval(mode: .adaptive, automaticMode: .advise,
                    thermal: .critical, active: false, scanning: false, countdown: false) == 30
                && SamplingCadencePolicy.interval(mode: .adaptive, automaticMode: .observe,
                    thermal: .nominal, active: false, scanning: false, countdown: false) == 60
                && SamplingCadencePolicy.interval(mode: .adaptive, automaticMode: .enforce,
                    thermal: .serious, active: false, scanning: false, countdown: true) == 5
        }

        check("内存偏好不同实例隔离且删除覆盖所有类型", failures: &failures) {
            let first = InMemoryPreferences()
            let second = InMemoryPreferences()
            let payload = Data([1, 2, 3])
            first.set(payload, forKey: "data")
            first.set(["one": "value"], forKey: "dictionary")
            let typedValues = first.data(forKey: "data") == payload
                && first.dictionary(forKey: "dictionary")?["one"] as? String == "value"
            let independent = second.object(forKey: "data") == nil
                && second.object(forKey: "dictionary") == nil
            first.set(nil, forKey: "data")
            first.set(nil, forKey: "dictionary")
            return typedValues && independent && first.object(forKey: "data") == nil
                && first.object(forKey: "dictionary") == nil
        }

        check("异步温度与最终执行共用有限值传感器数和时效门禁", failures: &failures) {
            let now = Date(timeIntervalSince1970: 100_000)
            func valid(_ value: Double = 75, age: TimeInterval = 0, sensors: Int = 1,
                       maximumAge: TimeInterval = 90) -> Bool {
                TemperatureReading(celsius: value, sensorCount: sensors, source: .appleSMC,
                    date: now.addingTimeInterval(-age)).isUsable(at: now, maximumAge: maximumAge)
            }
            return valid() && valid(age: 90) && valid(age: 45, maximumAge: 45)
                && !valid(age: 46, maximumAge: 45) && !valid(age: 91) && !valid(age: -1)
                && !valid(.nan) && !valid(.infinity) && !valid(0) && !valid(150)
                && !valid(sensors: 0) && !valid(age: .nan)
        }

        check("硬件温度参考线不被公共热状态覆盖", failures: &failures) {
            let date = Date(timeIntervalSince1970: 100_000)
            let normal = TemperatureReading(celsius: 64.9, sensorCount: 1,
                source: .appleSMC, date: date)
            let anomaly = TemperatureReading(celsius: 65, sensorCount: 1,
                source: .appleSMC, date: date)
            let enforce = TemperatureReading(celsius: 70, sensorCount: 1,
                source: .appleSMC, date: date)
            return normal.band == .normal && anomaly.band == .anomaly
                && enforce.band == .enforceReference
                && enforce.band.detail.contains("20 分钟")
        }

        check("单核满载等于进程 100%", failures: &failures) {
            let identity = ProcessIdentity(pid: 99, startAbstime: 123)
            let start = Date(timeIntervalSince1970: 1_000)
            let before = rawSample(identity: identity, cpu: 1_000_000_000, wakeups: 30, disk: 100)
            let after = rawSample(identity: identity, cpu: 3_000_000_000, wakeups: 38, disk: 300)
            let values = DeltaCalculator.processes(
                previous: Snapshot(date: start, hostTicks: nil, processes: [before], thermal: .nominal),
                current: Snapshot(date: start.addingTimeInterval(2), hostTicks: nil, processes: [after], thermal: .nominal)
            )
            return values.count == 1
                && abs(values[0].cpuPercent - 100) < 0.001
                && abs(values[0].wakeupsPerSecond - 4) < 0.001
                && abs(values[0].diskBytesPerSecond - 100) < 0.001
        }

        check("高 CPU 低 I/O 只形成空转提示证据", failures: &failures) {
            ActivitySignature.lowIOHighCPU(cpuPercent: 120, diskBytesPerSecond: 0, wakeupsPerSecond: 20)
                && !ActivitySignature.lowIOHighCPU(cpuPercent: 120,
                    diskBytesPerSecond: 2 * 1_048_576, wakeupsPerSecond: 20)
                && ActivitySignature.highIODuringCPU(diskBytesPerSecond: 2 * 1_048_576,
                    wakeupsPerSecond: 20)
        }

        check("PID 复用不会串进程", failures: &failures) {
            let start = Date(timeIntervalSince1970: 1_000)
            let old = rawSample(identity: ProcessIdentity(pid: 42, startAbstime: 1), cpu: 1_000)
            let reused = rawSample(identity: ProcessIdentity(pid: 42, startAbstime: 2), cpu: 9_000)
            return DeltaCalculator.processes(
                previous: Snapshot(date: start, hostTicks: nil, processes: [old], thermal: .nominal),
                current: Snapshot(date: start.addingTimeInterval(2), hostTicks: nil, processes: [reused], thermal: .nominal)
            ).isEmpty
        }

        check("辅助进程归属外层 App", failures: &failures) {
            let path = "/Applications/Example.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Helper"
            return AppResolver.appRoot(from: path) == "/Applications/Example.app"
        }

        for result in AppRootLookupRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in ExplicitConsentRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in ProcessAncestryRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in InheritedProtectionRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }

        check("高热但无 CPU 证据时不栽赃", failures: &failures) {
            let report = ReportBuilder.make(duration: 30, thermal: .serious, hostCPU: 15, processes: [])
            return report.summary.contains("没有充分解释")
        }

        check("系统媒体与存储分析给出可执行的等待建议", failures: &failures) {
            let media = LocalKnowledgeBase.advice(name: "mediaanalysisd",
                path: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/mediaanalysisd",
                bundleIdentifier: nil)
            let storage = LocalKnowledgeBase.advice(name: "ApplicationsStorageExtension",
                path: "/System/Library/PrivateFrameworks/StorageManagement.framework/ApplicationsStorageExtension",
                bundleIdentifier: nil)
            return media.protected && storage.protected
                && media.recommendation.contains("分析")
                && storage.recommendation.contains("存储")
        }

        check("65°C 连续五分钟即产生主机热异常观察", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .advise)
            let start = Date(timeIntervalSince1970: 1_500)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 300.0, by: 30.0) {
                let point = start.addingTimeInterval(offset)
                decision = engine.observe(now: point, temperature: 66, temperatureDate: point,
                    processes: [], settings: settings, isScanning: false)
            }
            return decision.kind == .anomaly && decision.process == nil
                && decision.reason.contains("异常参考线")
        }

        check("系统深扫只解析第二帧", failures: &failures) {
            let fixture = """
            PID UID %CPU COMMAND
            10 501 0.0 FirstFrame

            PID UID %CPU COMMAND
            20 88 40.5 WindowServer
            21 0 6.0 top
            """
            let values = TopSampler.parseRows(fixture)
            return values.count == 1 && values[0].pid == 20 && abs(values[0].cpuPercent - 40.5) < 0.001
        }

        check("温度后端的硬件值合理或明确不可用", failures: &failures) {
            #if arch(arm64) || arch(x86_64)
            var sample = HGTemperatureSample()
            let available = hg_read_cpu_temperature(&sample) == 1
            return !available || (sample.cpu_celsius.isFinite && sample.cpu_celsius > 0 && sample.cpu_celsius <= 150)
            #else
            return true
            #endif
        }

        check("单次高 CPU 不判定为空转", failures: &failures) {
            var engine = AnalysisEngine()
            let identity = ProcessIdentity(pid: 991, startAbstime: 1)
            let delta = processDelta(identity: identity, cpu: 80)
            let rows = engine.analyze(deltas: [delta], at: Date(timeIntervalSince1970: 2_000),
                                      thermal: .nominal, limited: [], ownPID: getpid())
            return rows.count == 1 && rows[0].risk <= .watch
        }

        check("持续后台证据才升级风险", failures: &failures) {
            var engine = AnalysisEngine()
            let identity = ProcessIdentity(pid: 992, startAbstime: 1)
            let first = Date(timeIntervalSince1970: 3_000)
            _ = engine.analyze(deltas: [processDelta(identity: identity, cpu: 45)], at: first,
                               thermal: .nominal, limited: [], ownPID: getpid())
            _ = engine.analyze(deltas: [processDelta(identity: identity, cpu: 45)], at: first.addingTimeInterval(30),
                               thermal: .nominal, limited: [], ownPID: getpid())
            let rows = engine.analyze(deltas: [processDelta(identity: identity, cpu: 45)], at: first.addingTimeInterval(61),
                                      thermal: .nominal, limited: [], ownPID: getpid())
            return rows.count == 1 && rows[0].risk >= .elevated && rows[0].isBackground
        }

        check("前台高负载不累积为后台空转证据", failures: &failures) {
            var engine = AnalysisEngine()
            let identity = ProcessIdentity(pid: 993, startAbstime: 1)
            let delta = processDelta(identity: identity, cpu: 90)
            let start = Date()
            for offset in [0.0, 30, 61] {
                _ = engine.analyze(deltas: [delta], at: start.addingTimeInterval(offset), thermal: .nominal,
                    limited: [], ownPID: getpid(), context: AnalysisContext(foregroundPID: identity.pid))
            }
            let rows = engine.analyze(deltas: [delta], at: start.addingTimeInterval(65), thermal: .nominal,
                                     limited: [], ownPID: getpid())
            return rows.first?.risk == .watch
        }
        check("前台应用的子进程继承用户意图保护", failures: &failures) {
            var engine = AnalysisEngine()
            let child = ProcessIdentity(pid: 9931, startAbstime: 1)
            let terminal = pid_t(9932)
            let delta = processDelta(identity: child, cpu: 90, parentPID: terminal)
            let context = AnalysisContext(foregroundPID: terminal)
            let row = engine.analyze(deltas: [delta], at: Date(timeIntervalSince1970: 4_000),
                                     thermal: .nominal, limited: [], ownPID: getpid(), context: context).first
            return row?.isForeground == true && row?.isProtected == true
        }
        check("长采样间隔会中断持续证据", failures: &failures) {
            var engine = AnalysisEngine()
            let delta = processDelta(identity: ProcessIdentity(pid: 994, startAbstime: 1), cpu: 90)
            let start = Date()
            for offset in [0.0, 30, 61] {
                _ = engine.analyze(deltas: [delta], at: start.addingTimeInterval(offset), thermal: .nominal,
                                   limited: [], ownPID: getpid())
            }
            return engine.analyze(deltas: [delta], at: start.addingTimeInterval(160), thermal: .nominal,
                                  limited: [], ownPID: getpid()).first?.risk == .watch
        }
        check("中途缺样会中断持续后台证据", failures: &failures) {
            var engine = AnalysisEngine()
            let delta = processDelta(identity: ProcessIdentity(pid: 1994, startAbstime: 1), cpu: 90)
            let start = Date()
            for offset in [0.0, 30] {
                _ = engine.analyze(deltas: [delta], at: start.addingTimeInterval(offset), thermal: .nominal,
                                   limited: [], ownPID: getpid())
            }
            _ = engine.analyze(deltas: [], at: start.addingTimeInterval(45), thermal: .nominal,
                               limited: [], ownPID: getpid())
            let resumed = engine.analyze(deltas: [delta], at: start.addingTimeInterval(61), thermal: .nominal,
                                         limited: [], ownPID: getpid())
            _ = engine.analyze(deltas: [delta], at: start.addingTimeInterval(91), thermal: .nominal,
                               limited: [], ownPID: getpid())
            let sustainedAgain = engine.analyze(deltas: [delta], at: start.addingTimeInterval(122), thermal: .nominal,
                                                limited: [], ownPID: getpid())
            return resumed.first?.risk == .watch && sustainedAgain.first?.risk == .elevated
                && resumed.first?.evidence.contains(where: { $0.contains("连续高占用") }) == false
        }
        check("应用重启不继承旧实例风险", failures: &failures) {
            var engine = AnalysisEngine()
            let old = ProcessIdentity(pid: 995, startAbstime: 1), new = ProcessIdentity(pid: 996, startAbstime: 2)
            let metadata = AppMetadata(displayName: "Test", bundleIdentifier: "test.worker", bundleRoot: "/tmp/Test.app")
            let context = AnalysisContext(metadata: [old: metadata, new: metadata])
            let start = Date()
            for offset in [0.0, 30, 61] {
                _ = engine.analyze(deltas: [processDelta(identity: old, cpu: 90)], at: start.addingTimeInterval(offset),
                    thermal: .nominal, limited: [], ownPID: getpid(), context: context)
            }
            return engine.analyze(deltas: [processDelta(identity: new, cpu: 90)], at: start.addingTimeInterval(65),
                thermal: .nominal, limited: [], ownPID: getpid(), context: context).first?.risk == .watch
        }
        check("同路径的独立进程不会合并报告", failures: &failures) {
            var engine = AnalysisEngine()
            let rows = engine.analyze(deltas: [
                processDelta(identity: ProcessIdentity(pid: 997, startAbstime: 1), cpu: 30),
                processDelta(identity: ProcessIdentity(pid: 998, startAbstime: 1), cpu: 20)
            ], at: Date(), thermal: .nominal, limited: [], ownPID: getpid())
            return rows.count == 2 && Set(rows.map(\.groupKey)).count == 2
        }
        check("应用组的精确可执行文件必须属于主身份而非最高 CPU 辅助进程", failures: &failures) {
            var engine = AnalysisEngine()
            let main = ProcessIdentity(pid: 1011, startAbstime: 1)
            let helper = ProcessIdentity(pid: 1012, startAbstime: 2)
            let root = "/tmp/Exact.app"
            let mainPath = root + "/Contents/MacOS/Main"
            let helperPath = root + "/Contents/Helpers/Worker"
            let metadata = AppMetadata(displayName: "Exact", bundleIdentifier: "test.exact", bundleRoot: root)
            let context = AnalysisContext(metadata: [main: metadata, helper: metadata], mainApplicationPIDs: [main.pid])
            let rows = engine.analyze(deltas: [processDelta(identity: main, cpu: 5, path: mainPath),
                processDelta(identity: helper, cpu: 180, path: helperPath)], at: Date(), thermal: .nominal,
                limited: [], ownPID: getpid(), context: context)
            guard let row = rows.first else { return false }
            return rows.count == 1 && row.id == main && row.path == root
                && row.executablePath == mainPath && row.withCPU(55).executablePath == mainPath
        }
        check("旧报告缺少精确可执行文件时正常解码但不能取得自动权限", failures: &failures) {
            let process = autoProcess(pid: 1013, cpu: 180, risk: .high)
            guard let encoded = try? JSONEncoder().encode(process),
                  var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return false }
            object.removeValue(forKey: "executablePath")
            object.removeValue(forKey: "wakeupsAvailable")
            object.removeValue(forKey: "diskAvailable")
            guard let legacy = try? JSONSerialization.data(withJSONObject: object),
                  let restored = try? JSONDecoder().decode(AppProcess.self, from: legacy) else { return false }
            var engine = AutomaticProtectionEngine()
            let settings = testAutoSettings()
            let start = Date(timeIntervalSince1970: 190_000)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [restored], settings: settings, isScanning: false)
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            return restored.executablePath == nil && !restored.wakeupsAvailable && !restored.diskAvailable
                && AutomaticTerminationGrant(process: restored) == nil
                && !engine.hasAutomaticAuthority(for: restored)
                && decision.kind == .anomaly && decision.reason.contains("可执行文件身份")
        }
        check("执行门禁拒绝同 bundle 同 PID 的不同可执行文件", failures: &failures) {
            let process = autoProcess(pid: 1014, cpu: 180, risk: .high)
            guard let executablePath = process.executablePath else { return false }
            func raw(_ path: String) -> RawProcessSample {
                RawProcessSample(identity: process.id, parentPID: 1, uid: getuid(), name: "worker", path: path,
                    cpuTimeNanoseconds: 1, interruptWakeups: 0, packageWakeups: 0, diskBytes: 0, residentBytes: 0)
            }
            let unchanged = ActionSafety.canLower(raw(executablePath), identity: process.id, app: process,
                foregroundPID: nil, foregroundBundle: nil, protectedKeys: [])
            let changed = ActionSafety.canLower(raw("/tmp/Worker.app/Contents/MacOS/replacement"),
                identity: process.id, app: process, foregroundPID: nil, foregroundBundle: nil, protectedKeys: [])
            return unchanged && !changed
        }
        check("末尾快照不能覆盖观察期均值", failures: &failures) {
            var engine = AnalysisEngine()
            let row = engine.analyze(deltas: [processDelta(identity: ProcessIdentity(pid: 999, startAbstime: 1), cpu: 25)],
                                     at: Date(), thermal: .nominal, limited: [], ownPID: getpid())[0]
            let merged = ReportMerger.merge(observed: [row], deep: [row.withCPU(150)])
            return merged.count == 1 && merged[0].cpuPercent == 25
        }
        check("深扫缺少第二帧或非有限数值时不采信", failures: &failures) {
            TopSampler.parseRows("PID UID %CPU COMMAND\n10 501 80 First").isEmpty
            && TopSampler.parseRows("PID UID %CPU COMMAND\n10 501 0 First\nPID UID %CPU COMMAND\n10 501 nan Worker").isEmpty
        }
        check("跨睡眠或时间跳变不计算进程增量", failures: &failures) {
            let identity = ProcessIdentity(pid: 1000, startAbstime: 1), start = Date()
            return DeltaCalculator.processes(
                previous: Snapshot(date: start, uptime: 10, hostTicks: nil,
                                   processes: [rawSample(identity: identity, cpu: 100)], thermal: .nominal),
                current: Snapshot(date: start.addingTimeInterval(3600), uptime: 15, hostTicks: nil,
                                  processes: [rawSample(identity: identity, cpu: 900)], thermal: .nominal)).isEmpty
        }
        check("跨睡眠整机 CPU 不产生趋势或均值样本", failures: &failures) {
            let start = Date()
            let previous = Snapshot(date: start, uptime: 10,
                hostTicks: HostTicks(user: 100, system: 50, idle: 850, nice: 0), processes: [], thermal: .nominal)
            let current = Snapshot(date: start.addingTimeInterval(3600), uptime: 15,
                hostTicks: HostTicks(user: 160, system: 90, idle: 950, nice: 0), processes: [], thermal: .nominal)
            let cpu = DeltaCalculator.hostCPU(previous: previous, current: current)
            var accumulator = ScanAccumulator()
            accumulator.append(MonitoringResult(date: current.date, thermal: .nominal, cpu: cpu, processes: [],
                loadAverage: 0, totalProcessCount: 0, readableProcessCount: 0, ownCPU: 0, ownMemory: 0,
                elapsedMilliseconds: 0), seconds: 5)
            return cpu == nil && accumulator.duration == 0
        }
        check("趋势有界且保留分钟峰值", failures: &failures) {
            let now = Date(timeIntervalSince1970: 180_000)
            var points: [HostPoint] = []
            for second in stride(from: 0, through: 179_999, by: 5) {
                TrendBuffer.append(HostPoint(date: Date(timeIntervalSince1970: Double(second)),
                    cpuPercent: second % 60 == 55 ? 80 : 10, thermal: .nominal), to: &points)
            }
            let bounded = TrendBuffer.bounded(points, now: now)
            return bounded.count <= 1440 && bounded.last?.cpuPercent == 80
                && bounded.allSatisfy { now.timeIntervalSince($0.date) <= 86_400 }
        }
        check("热暴露账本只累计连续有效区间并正确跨日", failures: &failures) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let start = Date(timeIntervalSince1970: 1_767_311_970) // 2026-01-01 23:59:30 UTC
            var days: [ThermalExposureDay] = []
            ThermalExposureLedger.appendInterval(from: start, to: start.addingTimeInterval(90),
                lowerBoundTemperature: 70, peakTemperature: 72, hostCPUPercent: 120,
                into: &days, calendar: calendar)
            guard days.count == 2 else { return false }
            return abs(days[0].coveredMinutes - 0.5) < 0.001
                && abs(days[1].coveredMinutes - 1.0) < 0.001
                && abs(days[0].above65Minutes - 0.5) < 0.001
                && abs(days[1].above70Minutes - 1.0) < 0.001
                && days.allSatisfy { $0.peakTemperatureCelsius == 72 && $0.peakHostCPUPercent == 120 }
        }
        check("热暴露账本拒绝长间隔和异常值并限制天数", failures: &failures) {
            var days: [ThermalExposureDay] = []
            let start = Date(timeIntervalSince1970: 2_000_000_000)
            ThermalExposureLedger.appendInterval(from: start, to: start.addingTimeInterval(91),
                lowerBoundTemperature: 80, peakTemperature: 80, hostCPUPercent: 100, into: &days)
            ThermalExposureLedger.appendInterval(from: start, to: start.addingTimeInterval(60),
                lowerBoundTemperature: .nan, peakTemperature: 80, hostCPUPercent: 100, into: &days)
            for offset in 0..<450 {
                let day = Date(timeIntervalSince1970: 1_600_000_000 + Double(offset) * 86_400)
                days.append(ThermalExposureDay(day: Calendar.autoupdatingCurrent.startOfDay(for: day)))
            }
            let bounded = ThermalExposureLedger.bounded(days, now: Date(timeIntervalSince1970: 1_600_000_000 + 449 * 86_400))
            return days.isEmpty == false && bounded.count <= ThermalExposureLedger.maximumDays
        }
        check("用户保护适用于独立可执行程序", failures: &failures) {
            var engine = AnalysisEngine()
            let row = engine.analyze(deltas: [processDelta(identity: ProcessIdentity(pid: 1001, startAbstime: 1), cpu: 90)],
                at: Date(), thermal: .nominal, limited: [], ownPID: getpid(),
                context: AnalysisContext(protectedBundleIDs: ["/tmp/worker"])).first
            return row?.isProtected == true
        }
        check("未知后台达到五分钟异常仍提醒，但不自动结束", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let process = autoProcess(pid: 1004, cpu: 180, risk: .high)
            let start = Date(timeIntervalSince1970: 9_000)
            for offset in stride(from: 0.0, through: 1_800.0, by: 60.0) {
                let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                                            processes: [process], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
                if offset >= 300 && result.kind != .anomaly { return false }
            }
            return true
        }
        check("本次运行授权只接受完整单进程身份且逐字段绑定", failures: &failures) {
            let process = autoProcess(pid: 1100, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: process), grant.matches(process: process),
                  grant.identity == process.id, grant.path == process.path else { return false }
            let changed = [
                autoProcess(pid: 1100, cpu: 180, risk: .high, identity: ProcessIdentity(pid: 1100, startAbstime: 2)),
                autoProcess(pid: 1101, cpu: 180, risk: .high),
                autoProcess(pid: 1100, cpu: 180, risk: .high, path: "/tmp/Changed.app"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, bundleIdentifier: "test.changed"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, bundleIdentifier: nil),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: "/tmp/Worker.app/Contents/MacOS/replacement")
            ]
            let malformed = [
                autoProcess(pid: 0, cpu: 180, risk: .high),
                autoProcess(pid: 1100, cpu: 180, risk: .high, identity: ProcessIdentity(pid: 1100, startAbstime: 0)),
                autoProcess(pid: 1100, cpu: 180, risk: .high, identity: ProcessIdentity(pid: 1101, startAbstime: 1)),
                autoProcess(pid: 1100, cpu: 180, risk: .high, memberIdentities: []),
                autoProcess(pid: 1100, cpu: 180, risk: .high, memberIdentities: [ProcessIdentity(pid: 1101, startAbstime: 1)]),
                autoProcess(pid: 1100, cpu: 180, risk: .high, memberIdentities: [process.id, ProcessIdentity(pid: 1101, startAbstime: 1)]),
                autoProcess(pid: 1100, cpu: 180, risk: .high, path: ""),
                autoProcess(pid: 1100, cpu: 180, risk: .high, path: "relative/worker"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, path: "/"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, path: "/tmp/worker\0ignored"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: nil),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: ""),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: "relative/worker"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: "/"),
                autoProcess(pid: 1100, cpu: 180, risk: .high, executablePath: "/tmp/worker\0ignored")
            ]
            return changed.allSatisfy { !grant.matches(process: $0) }
                && malformed.allSatisfy { AutomaticTerminationGrant(process: $0) == nil && !grant.matches(process: $0) }
        }
        check("默认规则允许已授权纯后台在完整二十分钟和倒计时后处理", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let process = autoProcess(pid: 1110, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            let grants: Set<AutomaticTerminationGrant> = [grant]
            let start = Date(timeIntervalSince1970: 200_000)
            guard !engine.hasAutomaticAuthority(for: process),
                  engine.hasAutomaticAuthority(for: process, authorizedTargets: grants) else { return false }
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false, authorizedTargets: grants)
                if result.kind == .countdown || result.kind == .enforce { return false }
                if offset >= 300 && result.kind != .anomaly { return false }
            }
            let countdown = engine.observe(now: start.addingTimeInterval(1_200), temperature: 75,
                processes: [process], settings: settings, isScanning: false, authorizedTargets: grants)
            let beforeDeadline = engine.observe(now: start.addingTimeInterval(1_229), temperature: 75,
                processes: [process], settings: settings, isScanning: false, authorizedTargets: grants)
            let enforce = engine.observe(now: start.addingTimeInterval(1_230), temperature: 75,
                processes: [process], settings: settings, isScanning: false, authorizedTargets: grants)
            return countdown.kind == .countdown && beforeDeadline.kind == .countdown
                && enforce.kind == .enforce && enforce.process?.id == process.id
        }
        check("明确授权仍需连续低 I/O，活动任务不会自动结束", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let process = autoProcess(pid: 11101, cpu: 180, risk: .high,
                diskBytesPerSecond: 2 * 1_048_576)
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            let start = Date(timeIntervalSince1970: 204_000)
            var last = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                last = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false,
                    authorizedTargets: [grant])
                if last.kind == .countdown || last.kind == .enforce { return false }
            }
            return last.kind == .anomaly && last.reason.contains("低 I/O")
        }
        check("可选空转范围允许连续低 I/O 后自动处置未授权单进程", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let process = autoProcess(pid: 1111, cpu: 180, risk: .high)
            let start = Date(timeIntervalSince1970: 205_000)
            guard !engine.hasAutomaticAuthority(for: process) else { return false }
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            let countdown = engine.observe(now: start.addingTimeInterval(1_200), temperature: 75,
                processes: [process], settings: settings, isScanning: false)
            let enforce = engine.observe(now: start.addingTimeInterval(1_230), temperature: 75,
                processes: [process], settings: settings, isScanning: false)
            return countdown.kind == .countdown && countdown.reason.contains("低 I/O")
                && enforce.kind == .enforce && enforce.process?.id == process.id
        }
        check("直接模式跳过倒计时但仍要求空转范围", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce,
                automaticTerminationScope: .clearIdle, automaticTerminationTiming: .immediate)
            let process = autoProcess(pid: 1119, cpu: 180, risk: .high)
            let start = Date(timeIntervalSince1970: 205_300)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            let direct = engine.observe(now: start.addingTimeInterval(1_200), temperature: 75,
                processes: [process], settings: settings, isScanning: false)
            let cooldown = engine.observe(now: start.addingTimeInterval(1_201), temperature: 75,
                processes: [process], settings: settings, isScanning: false)
            var explicitOnly = settings
            explicitOnly.automaticTerminationScope = .explicitGrant
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            var guardedEngine = AutomaticProtectionEngine()
            var guarded = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_200.0, by: 30.0) {
                guarded = guardedEngine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: explicitOnly, isScanning: false,
                    authorizedTargets: [grant])
            }
            return direct.kind == .enforce && direct.process?.id == process.id
                && direct.reason.contains("直接自动结束")
                && cooldown.kind != .enforce
                && guarded.kind == .anomaly && guarded.reason.contains("直接自动结束")
        }
        check("直接模式说明退出或停止后会恢复取消窗口", failures: &failures) {
            let detail = AutomaticTerminationTiming.immediate.detail
            return detail.contains("退出或重启温衡")
                && detail.contains("恢复为 30 秒可取消")
                && detail.contains("重新启用直接模式需要再次确认")
        }
        check("自动处置进度与决策共用同一份连续证据", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let process = autoProcess(pid: 1118, cpu: 180, risk: .high)
            let start = Date(timeIntervalSince1970: 205_900)
            for offset in stride(from: 0.0, through: 300.0, by: 30.0) {
                let point = start.addingTimeInterval(offset)
                _ = engine.observe(now: point, temperature: 75, temperatureDate: point,
                                   processes: [process], settings: settings, isScanning: false)
            }
            guard let progress = engine.evidence(for: process,
                now: start.addingTimeInterval(300), settings: settings), progress.isRelevant else {
                return false
            }
            return progress.highCPUDuration >= 300
                && progress.idleDuration >= 300
                && progress.enforceTemperatureDuration >= 300
                && progress.summary.contains("CPU 5分钟/20分钟")
                && progress.summary.contains("异常温度 65°C 5分钟/5分钟")
                && progress.summary.contains("执行温度 70°C 5分钟/20分钟")
                && progress.summary.contains("只提醒")
        }
        check("安全临时命令行范围允许未授权空转任务但拒绝工程来源", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdleWithEphemeralCLI)
            let safe = autoProcess(pid: 1116, cpu: 180, risk: .high,
                path: "/private/tmp/heatguard-idle-worker", bundleIdentifier: nil,
                executablePath: "/private/tmp/heatguard-idle-worker")
            let project = autoProcess(pid: 1117, cpu: 180, risk: .high,
                path: "/private/tmp/project-worker/build/worker", bundleIdentifier: nil,
                executablePath: "/private/tmp/project-worker/build/worker")
            guard LocalKnowledgeBase.isEphemeralCommandLineTarget(
                    name: safe.name, path: safe.path, bundleIdentifier: safe.bundleIdentifier,
                    executablePath: safe.executablePath),
                  !LocalKnowledgeBase.isEphemeralCommandLineTarget(
                    name: project.name, path: project.path, bundleIdentifier: project.bundleIdentifier,
                    executablePath: project.executablePath) else { return false }
            var safeEngine = AutomaticProtectionEngine()
            let start = Date(timeIntervalSince1970: 205_500)
            var safeDecision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_200.0, by: 30.0) {
                safeDecision = safeEngine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [safe], settings: settings, isScanning: false, authorizedTargets: [])
            }
            guard safeDecision.kind == .countdown else { return false }
            let safeEnforce = safeEngine.observe(now: start.addingTimeInterval(1_230), temperature: 75,
                processes: [safe], settings: settings, isScanning: false, authorizedTargets: [])
            var projectEngine = AutomaticProtectionEngine()
            var projectDecision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                projectDecision = projectEngine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [project], settings: settings, isScanning: false, authorizedTargets: [])
            }
            return safeEnforce.kind == .enforce && safeEnforce.process?.id == safe.id
                && projectDecision.kind == .anomaly && projectDecision.reason.contains("只提醒")
        }
        check("临时命令行符号链接不绕过工程路径保护", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("HeatGuard-symlink-\(UUID().uuidString)")
            let project = root.appendingPathComponent("project")
            let target = project.appendingPathComponent("worker")
            let alias = root.appendingPathComponent("worker-alias")
            do {
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
                defer { try? FileManager.default.removeItem(at: root) }
                return !LocalKnowledgeBase.isEphemeralCommandLineTarget(
                    name: "worker", path: alias.path, bundleIdentifier: nil,
                    executablePath: alias.path)
            } catch {
                try? FileManager.default.removeItem(at: root)
                return false
            }
        }
        check("空转范围遇到明显 I/O 时持续只提醒", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let process = autoProcess(pid: 1112, cpu: 180, risk: .high,
                diskBytesPerSecond: 2 * 1_048_576)
            let start = Date(timeIntervalSince1970: 206_000)
            var last = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                last = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if last.kind == .countdown || last.kind == .enforce { return false }
            }
            return last.kind == .anomaly && last.reason.contains("低 I/O")
        }
        check("空转范围不把受保护或降级期间的低活动抵扣新二十分钟", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let free = autoProcess(pid: 1195, cpu: 120, risk: .elevated)
            var project = free
            project.automaticContextBlockReason = "来自工程任务，只提醒。"
            let guarded = [
                autoProcess(pid: 1195, cpu: 120, risk: .elevated, protected: true),
                autoProcess(pid: 1195, cpu: 120, risk: .elevated, softLimited: true),
                project
            ]
            for blocked in guarded {
                var engine = AutomaticProtectionEngine()
                let start = Date(timeIntervalSince1970: 209_000)
                for seconds in stride(from: 0.0, through: 2_670.0, by: 30.0) {
                    let decision = engine.observe(now: start.addingTimeInterval(seconds), temperature: 80,
                        processes: [seconds < 1_500 ? blocked : free], settings: settings, isScanning: false)
                    if decision.kind == .countdown || decision.kind == .enforce { return false }
                }
                let countdown = engine.observe(now: start.addingTimeInterval(2_700), temperature: 80,
                    processes: [free], settings: settings, isScanning: false)
                let ended = engine.observe(now: start.addingTimeInterval(2_730), temperature: 80,
                    processes: [free], settings: settings, isScanning: false)
                guard countdown.kind == .countdown, ended.kind == .enforce else { return false }
            }
            return true
        }
        check("空转范围在最近使用保护结束后重新积累二十分钟", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let background = autoProcess(pid: 1196, cpu: 120, risk: .elevated)
            let start = Date(timeIntervalSince1970: 213_000)
            engine.recordForegroundUse(background, at: start)
            for seconds in stride(from: 30.0, through: 3_000.0, by: 30.0) {
                let decision = engine.observe(now: start.addingTimeInterval(seconds), temperature: 80,
                    processes: [background], settings: settings, isScanning: false)
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            let countdown = engine.observe(now: start.addingTimeInterval(3_030), temperature: 80,
                processes: [background], settings: settings, isScanning: false)
            return countdown.kind == .countdown
        }
        check("空转范围仍排除工程和媒体关键任务", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            let process = autoProcess(pid: 1113, cpu: 180, risk: .high,
                name: "ffmpeg", path: "/usr/local/bin/ffmpeg")
            let start = Date(timeIntervalSince1970: 207_000)
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            var commandEngine = AutomaticProtectionEngine()
            let command = autoProcess(pid: 1114, cpu: 180, risk: .high,
                path: "/usr/local/bin/project-worker", bundleIdentifier: nil)
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                let result = commandEngine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [command], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            var unavailableEngine = AutomaticProtectionEngine()
            let unavailable = autoProcess(pid: 1115, cpu: 180, risk: .high, metricsAvailable: false)
            for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                let result = unavailableEngine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [unavailable], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            return true
        }
        check("倒计时期间撤销本次授权立即退回提醒且执行前权限校验拒绝", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let process = autoProcess(pid: 1120, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            let start = Date(timeIntervalSince1970: 210_000)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_200.0, by: 30.0) {
                decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false, authorizedTargets: [grant])
            }
            guard decision.kind == .countdown,
                  !engine.hasAutomaticAuthority(for: process, authorizedTargets: []) else { return false }
            decision = engine.observe(now: start.addingTimeInterval(1_230), temperature: 75,
                processes: [process], settings: settings, isScanning: false, authorizedTargets: [])
            return decision.kind == .anomaly && decision.reason.contains("本次运行授权")
        }
        check("重启换路径或换应用身份不能继承旧授权即使持续高温", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce)
            let original = autoProcess(pid: 1130, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: original) else { return false }
            let changed = [
                autoProcess(pid: 1130, cpu: 180, risk: .high, identity: ProcessIdentity(pid: 1130, startAbstime: 2)),
                autoProcess(pid: 1130, cpu: 180, risk: .high, path: "/tmp/Changed.app"),
                autoProcess(pid: 1130, cpu: 180, risk: .high, bundleIdentifier: "test.changed"),
                autoProcess(pid: 1130, cpu: 180, risk: .high, executablePath: "/tmp/Worker.app/Contents/MacOS/replacement")
            ]
            for process in changed {
                var engine = AutomaticProtectionEngine()
                let start = Date(timeIntervalSince1970: 220_000)
                guard !engine.hasAutomaticAuthority(for: process, authorizedTargets: [grant]) else { return false }
                for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                    let decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                        processes: [process], settings: settings, isScanning: false, authorizedTargets: [grant])
                    if decision.kind == .countdown || decision.kind == .enforce { return false }
                    if offset >= 300 && decision.kind != .anomaly { return false }
                }
            }
            return true
        }
        check("本次运行授权不能越过系统保护名单前台或关键工作排除", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce)
            let excluded = [
                autoProcess(pid: 1140, cpu: 180, risk: .high, foreground: true),
                autoProcess(pid: 1141, cpu: 180, risk: .high, system: true),
                autoProcess(pid: 1142, cpu: 180, risk: .high, protected: true),
                autoProcess(pid: 1143, cpu: 180, risk: .high, softLimited: true),
                autoProcess(pid: 1144, cpu: 180, risk: .high, name: "swiftc", path: "/usr/local/bin/swiftc"),
                autoProcess(pid: 1145, cpu: 180, risk: .high, name: "ffmpeg", path: "/usr/local/bin/ffmpeg"),
                autoProcess(pid: 1146, cpu: 180, risk: .high, name: "ollama", path: "/usr/local/bin/ollama"),
                autoProcess(pid: 1147, cpu: 180, risk: .high, name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundleIdentifier: "com.google.Chrome"),
                autoProcess(pid: 1148, cpu: 50, risk: .high),
                autoProcess(pid: 1149, cpu: 180, risk: .watch)
            ]
            for process in excluded {
                guard let grant = AutomaticTerminationGrant(process: process) else { return false }
                var engine = AutomaticProtectionEngine()
                let start = Date(timeIntervalSince1970: 230_000)
                for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                    let decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 80,
                        processes: [process], settings: settings, isScanning: false, authorizedTargets: [grant])
                    if decision.kind == .countdown || decision.kind == .enforce { return false }
                }
            }
            return true
        }
        check("本次运行授权不能绕过最近三十分钟的使用保护", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let foreground = autoProcess(pid: 1150, cpu: 180, risk: .high, foreground: true)
            let background = autoProcess(pid: 1150, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: background) else { return false }
            let start = Date(timeIntervalSince1970: 240_000)
            _ = engine.observe(now: start, temperature: 75, processes: [foreground],
                settings: settings, isScanning: false, authorizedTargets: [grant])
            for offset in stride(from: 30.0, through: 3_000.0, by: 30.0) {
                let decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [background], settings: settings, isScanning: false, authorizedTargets: [grant])
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            return engine.observe(now: start.addingTimeInterval(3_030), temperature: 75,
                processes: [background], settings: settings, isScanning: false, authorizedTargets: [grant]).kind == .countdown
        }
        check("本次运行授权不会将异常温度扫描或提醒模式变成自动结束", failures: &failures) {
            let process = autoProcess(pid: 1160, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            let scenarios: [(Double, Bool, AutoProtectionMode)] = [(66, false, .enforce), (75, true, .enforce), (75, false, .advise)]
            for (temperature, scanning, mode) in scenarios {
                var engine = AutomaticProtectionEngine()
                let settings = AutoProtectionSettings(mode: mode)
                let start = Date(timeIntervalSince1970: 250_000)
                for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                    let decision = engine.observe(now: start.addingTimeInterval(offset), temperature: temperature,
                        processes: [process], settings: settings, isScanning: scanning, authorizedTargets: [grant])
                    if decision.kind == .countdown || decision.kind == .enforce { return false }
                    if offset >= 300 && decision.kind != .anomaly { return false }
                }
            }
            return true
        }
        check("前台历史在保护期结束后也不能代替明确授权", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let foreground = autoProcess(pid: 1005, cpu: 180, risk: .high, foreground: true)
            let background = autoProcess(pid: 1005, cpu: 180, risk: .high)
            let start = Date(timeIntervalSince1970: 12_000)
            _ = engine.observe(now: start, temperature: 75, processes: [foreground], settings: settings, isScanning: false)
            // Keep the temperature chain alive while the same identity is
            // backgrounded; recent-use protection ends after 30 minutes.
            for offset in stride(from: 30.0, through: 3_120.0, by: 30.0) {
                let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                                            processes: [background], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            return !engine.hasAutomaticAuthority(for: background)
        }
        check("前台历史也不能为重启或换路径的目标授予自动权限", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce)
            let start = Date(timeIntervalSince1970: 20_000)
            let foreground = autoProcess(pid: 1006, cpu: 180, risk: .high, foreground: true)
            let changed = [
                autoProcess(pid: 1006, cpu: 180, risk: .high,
                            identity: ProcessIdentity(pid: 1006, startAbstime: 2)),
                autoProcess(pid: 1006, cpu: 180, risk: .high, path: "/tmp/Different.app"),
                autoProcess(pid: 1006, cpu: 180, risk: .high, executablePath: "/tmp/Worker.app/Contents/MacOS/replacement")
            ]
            for process in changed {
                var engine = AutomaticProtectionEngine()
                _ = engine.observe(now: start, temperature: 75, processes: [foreground],
                                   settings: settings, isScanning: false)
                for offset in stride(from: 30.0, through: 3_300.0, by: 30.0) {
                    let result = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                                                processes: [process], settings: settings, isScanning: false)
                    if result.kind == .enforce || result.kind == .countdown { return false }
                    if offset >= 2_130 && result.kind != .anomaly { return false }
                }
            }
            return true
        }
        check("更高占用的未知后台不遮蔽已满足自动处理门槛的目标", failures: &failures) {
            let settings = AutoProtectionSettings(mode: .enforce)
            let foreground = autoProcess(pid: 1007, cpu: 100, risk: .elevated, foreground: true,
                                         bundleIdentifier: "test.known")
            let known = autoProcess(pid: 1007, cpu: 100, risk: .elevated, bundleIdentifier: "test.known")
            guard let grant = AutomaticTerminationGrant(process: known) else { return false }
            let unknown = autoProcess(pid: 1008, cpu: 600, risk: .high, bundleIdentifier: "test.unknown")
            let start = Date(timeIntervalSince1970: 24_000)
            var engine = AutomaticProtectionEngine()
            _ = engine.observe(now: start, temperature: 80, processes: [foreground, unknown],
                               settings: settings, isScanning: false, authorizedTargets: [grant])
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 30.0, through: 3_030.0, by: 30.0) {
                decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 80,
                                          processes: [unknown, known], settings: settings, isScanning: false, authorizedTargets: [grant])
            }
            guard decision.kind == .countdown && decision.process?.id == known.id else { return false }
            decision = engine.observe(now: start.addingTimeInterval(3_060), temperature: 80,
                                      processes: [unknown, known], settings: settings, isScanning: false, authorizedTargets: [grant])
            return decision.kind == .enforce && decision.process?.id == known.id
        }
        check("旧设置保留模式和阈值但丢弃可绕过授权的历史开关", failures: &failures) {
            for suffix in ["", #","requireRecentForegroundHistory":true"#, #","requireRecentForegroundHistory":false"#] {
                let legacy = Data((#"{"mode":"advise","minimumCPUPercent":90,"recentForegroundGrace":2400"# + suffix + "}").utf8)
                guard let decoded = try? JSONDecoder().decode(AutoProtectionSettings.self, from: legacy),
                      let data = try? JSONEncoder().encode(decoded),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let restored = try? JSONDecoder().decode(AutoProtectionSettings.self, from: data) else { return false }
                guard object["requireRecentForegroundHistory"] == nil, restored.mode == .advise,
                      restored.minimumCPUPercent == 90, restored.recentForegroundGrace == 2400,
                      restored.enforceDuration == 1200,
                      restored.automaticTerminationScope == .explicitGrant,
                      restored.automaticTerminationTiming == .cancelWindow, restored.isSane else { return false }
            }
            let active = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdle)
            guard let encoded = try? JSONEncoder().encode(active),
                  let restored = try? JSONDecoder().decode(AutoProtectionSettings.self, from: encoded) else {
                return false
            }
            guard restored.automaticTerminationScope == .clearIdle else { return false }
            let cli = AutoProtectionSettings(mode: .enforce, automaticTerminationScope: .clearIdleWithEphemeralCLI)
            guard let cliData = try? JSONEncoder().encode(cli),
                  let cliRestored = try? JSONDecoder().decode(AutoProtectionSettings.self, from: cliData) else {
                return false
            }
            return cliRestored.automaticTerminationScope == .clearIdleWithEphemeralCLI
        }
        check("本地安装工具不被误判为系统进程", failures: &failures) {
            var engine = AnalysisEngine()
            let local = engine.analyze(deltas: [processDelta(
                identity: ProcessIdentity(pid: 1002, startAbstime: 1), cpu: 90,
                path: "/usr/local/bin/project-worker")], at: Date(), thermal: .nominal,
                limited: [], ownPID: getpid()).first
            let system = engine.analyze(deltas: [processDelta(
                identity: ProcessIdentity(pid: 1003, startAbstime: 1), cpu: 90,
                path: "/usr/bin/project-worker")], at: Date(), thermal: .nominal,
                limited: [], ownPID: getpid()).first
            return local?.isSystem == false && local?.isProtected == false
                && system?.isSystem == true && system?.isProtected == true
        }
        check("受保护浏览器工程与多进程负载照常提醒且不能自动结束", failures: &failures) {
            let main = ProcessIdentity(pid: 1801, startAbstime: 1)
            let targets = [
                autoProcess(pid: 1800, cpu: 100, risk: .elevated, name: "Chrome", bundleIdentifier: "test.chrome"),
                autoProcess(pid: main.pid, cpu: 100, risk: .elevated, identity: main,
                    memberIdentities: [main, ProcessIdentity(pid: 1802, startAbstime: 2)]),
                autoProcess(pid: 1803, cpu: 100, risk: .elevated, name: "swiftc"),
                autoProcess(pid: 1804, cpu: 100, risk: .watch, protected: true),
                autoProcess(pid: 1805, cpu: 100, risk: .watch, system: true),
                autoProcess(pid: 1806, cpu: 100, risk: .elevated, softLimited: true)
            ]
            for process in targets {
                for mode in [AutoProtectionMode.advise, .enforce] {
                    var engine = AutomaticProtectionEngine()
                    let settings = AutoProtectionSettings(mode: mode)
                    let start = Date(timeIntervalSince1970: 310_000)
                    for offset in stride(from: 0.0, through: 1_500.0, by: 30.0) {
                        let decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset),
                            temperature: offset <= 300 ? 67 : 80, processes: [process],
                            settings: settings, isScanning: false)
                        if offset < 300 && decision.kind == .anomaly { return false }
                        if offset >= 300 && (decision.kind != .anomaly || decision.process?.id != process.id) { return false }
                    }
                }
            }
            return true
        }
        check("受保护期间的诊断时长不能抵扣解除后的二十分钟", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let guarded = autoProcess(pid: 1810, cpu: 100, risk: .elevated, protected: true)
            let free = autoProcess(pid: 1810, cpu: 100, risk: .elevated)
            let start = Date(timeIntervalSince1970: 320_000)
            for offset in stride(from: 0.0, through: 2_670.0, by: 30.0) {
                let decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 80,
                    processes: [offset < 1_500 ? guarded : free], settings: settings, isScanning: false)
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            return engine.observeWithFixtureConsent(now: start.addingTimeInterval(2_700), temperature: 80,
                processes: [free], settings: settings, isScanning: false).kind == .countdown
        }
        check("高占用的提醒目标不遮蔽可执行目标的取消窗口", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let browser = autoProcess(pid: 1811, cpu: 600, risk: .high, name: "Chrome", bundleIdentifier: "test.chrome")
            let worker = autoProcess(pid: 1812, cpu: 100, risk: .elevated, bundleIdentifier: "test.worker")
            let start = Date(timeIntervalSince1970: 330_000)
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 80,
                    processes: [browser, worker], settings: settings, isScanning: false)
            }
            let countdown = engine.observeWithFixtureConsent(now: start.addingTimeInterval(1_200), temperature: 80,
                processes: [browser, worker], settings: settings, isScanning: false)
            let end = engine.observeWithFixtureConsent(now: start.addingTimeInterval(1_230), temperature: 80,
                processes: [browser, worker], settings: settings, isScanning: false)
            return countdown.kind == .countdown && countdown.process?.id == worker.id
                && end.kind == .enforce && end.process?.id == worker.id
        }
        check("降级效果排除跨动作窗口并按时长加权", failures: &failures) {
            let process = autoProcess(pid: 1820, cpu: 150, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 340_000)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start.addingTimeInterval(1)) else { return false }
            feedback.append(process, from: start, to: start.addingTimeInterval(10))
            guard feedback.averageCPU == nil else { return false }
            feedback.append(process.withCPU(120), from: start.addingTimeInterval(10), to: start.addingTimeInterval(30))
            guard feedback.summary.contains("暂不能比较") else { return false }
            feedback.append(process.withCPU(30), from: start.addingTimeInterval(30), to: start.addingTimeInterval(70))
            guard feedback.beforeCPU == 150, feedback.observedSeconds == 60,
                  feedback.averageCPU == 60, feedback.isComplete, !feedback.remainsHigh else { return false }
            feedback.append(process.withCPU(600), from: start.addingTimeInterval(70), to: start.addingTimeInterval(100))
            return feedback.averageCPU == 60 && feedback.observedSeconds == 60
        }
        check("Darwin 后台调度回读区别普通优先级", failures: &failures) {
            let normal = SchedulingObservation(priority: 31, nice: 0, state: "S",
                darwinPolicy: 0, darwinPriority: 31, darwinMaxPriority: 31,
                darwinThreadCount: 1, darwinReadableThreads: 1, darwinBackgroundThreads: 0)
            let background = SchedulingObservation(priority: 31, nice: 0, state: "S",
                darwinPolicy: 4, darwinPriority: 0, darwinMaxPriority: 4,
                darwinThreadCount: 1, darwinReadableThreads: 1, darwinBackgroundThreads: 1)
            let effect = PolicyEffectEvidence(before: normal, after: background, observedAt: Date())
            return normal.isKnownStandardBaseline && !normal.isDarwinBackground
                && background.isDarwinBackground && !background.isKnownStandardBaseline
                && effect.summary.contains("后台线程回读 0/1→1/1")
                && effect.summary.contains("不是 CPU 硬限速")
        }
        check("降级反馈明确显示 CPU 前后变化方向", failures: &failures) {
            let process = autoProcess(pid: 1824, cpu: 150, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 345_000)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start) else { return false }
            guard feedback.progressSummary.contains("正在观察处理后状态")
                    && feedback.progressSummary.contains("0/60 秒") else { return false }
            feedback.append(process.withCPU(20), from: start, to: start.addingTimeInterval(60))
            return feedback.isComplete
                && feedback.progressSummary.contains("观察窗口已完成")
                && feedback.summary.contains("下降 130.0 个百分点")
                && !feedback.summary.contains("下降 130.0%")
                && feedback.explanation.contains("CPU 有所下降")
        }
        check("降级反馈同时显示温度前后变化", failures: &failures) {
            let process = autoProcess(pid: 1828, cpu: 150, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 345_500)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                sampleTemperatureCelsius: 75, sampleTemperatureDate: start,
                applied: [process.id], startedAt: start) else { return false }
            feedback.append(process.withCPU(50), from: start, to: start.addingTimeInterval(60),
                            temperatureCelsius: 70, temperatureDate: start.addingTimeInterval(60))
            return feedback.isComplete
                && feedback.averageTemperatureCelsius == 70
                && feedback.summary.contains("温度 75.0°C → 70.0°C")
                && feedback.summary.contains("下降 5.0°C")
        }
        check("降级温度反馈拒绝过期基线", failures: &failures) {
            let process = autoProcess(pid: 1829, cpu: 150, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 345_600)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                sampleTemperatureCelsius: 75,
                sampleTemperatureDate: start.addingTimeInterval(-91),
                applied: [process.id], startedAt: start) else { return false }
            feedback.append(process.withCPU(50), from: start, to: start.addingTimeInterval(60),
                            temperatureCelsius: 70,
                            temperatureDate: start.addingTimeInterval(60))
            return feedback.isComplete && feedback.summary.contains("温度暂不能比较")
        }
        check("CPU 变化恰好五个百分点时方向说明一致", failures: &failures) {
            let start = Date(timeIntervalSince1970: 346_000)
            for (before, after, direction) in [(70.0, 65.0, "下降"), (60.0, 65.0, "上升")] {
                let process = autoProcess(pid: 1825, cpu: before, risk: .watch, softLimited: true)
                guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                    applied: [process.id], startedAt: start) else { return false }
                feedback.append(process.withCPU(after), from: start, to: start.addingTimeInterval(60))
                guard feedback.summary.contains(direction + " 5.0 个百分点"),
                      !feedback.explanation.contains("基本持平") else { return false }
            }
            return true
        }
        check("CPU 处理前基线不可用时不得声称持平或改善", failures: &failures) {
            let start = Date(timeIntervalSince1970: 347_000)
            let process = autoProcess(pid: 1826, cpu: 150, risk: .high, softLimited: true)
            guard var feedback = PolicyCPUObservation(process: process,
                sampleDate: start.addingTimeInterval(-91), applied: [process.id], startedAt: start) else { return false }
            feedback.append(process.withCPU(20), from: start, to: start.addingTimeInterval(60))
            return feedback.isComplete && feedback.summary.contains("暂不能比较")
                && feedback.explanation.contains("暂不能比较")
                && !feedback.explanation.contains("基本持平")
                && !feedback.explanation.contains("有所下降")
        }
        check("CPU 上升不推出调度无效且小波动保持中性说明", failures: &failures) {
            let start = Date(timeIntervalSince1970: 348_000)
            let process = autoProcess(pid: 1827, cpu: 40, risk: .watch, softLimited: true)
            guard var rising = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start),
                  var steady = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start) else { return false }
            rising.append(process.withCPU(60), from: start, to: start.addingTimeInterval(60))
            steady.append(process.withCPU(43), from: start, to: start.addingTimeInterval(60))
            return rising.summary.contains("上升 20.0 个百分点")
                && rising.explanation.contains("不能据此判断")
                && !rising.explanation.contains("没有解决")
                && steady.summary.contains("变化不足 5 个百分点")
                && steady.explanation.contains("基本持平")
        }
        check("降级效果缺帧或暂停后清除旧基线与均值", failures: &failures) {
            let process = autoProcess(pid: 1821, cpu: 100, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 350_000)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start) else { return false }
            feedback.append(process, from: start, to: start.addingTimeInterval(30))
            feedback.append(process, from: start.addingTimeInterval(60), to: start.addingTimeInterval(90))
            guard feedback.averageCPU == nil && feedback.beforeCPU == nil else { return false }
            feedback.append(process, from: start.addingTimeInterval(90), to: start.addingTimeInterval(150))
            guard feedback.remainsHigh else { return false }
            feedback.invalidate(at: start.addingTimeInterval(200))
            return feedback.averageCPU == nil && !feedback.isComplete && feedback.beforeCPU == nil
        }
        check("仍高 CPU 时提供手动入口但不无证据断言没有降温", failures: &failures) {
            let process = autoProcess(pid: 1823, cpu: 100, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 355_000)
            guard var feedback = PolicyCPUObservation(process: process, sampleDate: start,
                applied: [process.id], startedAt: start) else { return false }
            feedback.append(process, from: start, to: start.addingTimeInterval(60))
            return feedback.isComplete && feedback.remainsHigh
                && feedback.explanation.contains("不能单独证明")
                && !feedback.explanation.contains("没有达到降温效果")
                && feedback.explanation.contains("强制结束")
        }
        check("降级效果不复用重启或变更成员身份且过期前值不用于对比", failures: &failures) {
            let process = autoProcess(pid: 1822, cpu: 100, risk: .high, softLimited: true)
            let start = Date(timeIntervalSince1970: 360_000)
            guard let feedback = PolicyCPUObservation(process: process, sampleDate: start.addingTimeInterval(-91),
                applied: [process.id], startedAt: start) else { return false }
            let changed = autoProcess(pid: 1822, cpu: 100, risk: .high, identity: ProcessIdentity(pid: 1822, startAbstime: 2))
            let grouped = autoProcess(pid: 1822, cpu: 100, risk: .high,
                memberIdentities: [process.id, ProcessIdentity(pid: 1823, startAbstime: 1)])
            return feedback.beforeCPU == nil && !feedback.matches(changed) && !feedback.matches(grouped)
                && PolicyCPUObservation(process: process, sampleDate: start, applied: [], startedAt: start) == nil
        }
        check("自动保护遵守 65/70°C 连续证据与 30 秒倒计时", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 300
            settings.enforceDuration = 1200
            settings.minimumCPUPercent = 80
            let process = autoProcess(pid: 2001, cpu: 95, risk: .elevated)
            let start = Date(timeIntervalSince1970: 10_000)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1200.0, by: 60.0) {
                decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 71,
                    processes: [process], settings: settings, isScanning: false)
            }
            let countdown = decision.kind == .countdown
            engine.cancelCountdown()
            let blocked = engine.observeWithFixtureConsent(now: start.addingTimeInterval(1231), temperature: 71,
                processes: [process], settings: settings, isScanning: false).kind == .blocked
            var enforcingEngine = AutomaticProtectionEngine()
            for offset in stride(from: 0.0, through: 1200.0, by: 60.0) {
                _ = enforcingEngine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 71,
                    processes: [process], settings: settings, isScanning: false)
            }
            decision = enforcingEngine.observeWithFixtureConsent(now: start.addingTimeInterval(1231), temperature: 71,
                processes: [process], settings: settings, isScanning: false)
            return countdown && blocked && decision.kind == .enforce && decision.process?.id == process.id
        }
        check("自动保护优先选择更严重且已达到完整时长的目标", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let older = autoProcess(pid: 2041, cpu: 90, risk: .elevated,
                                    bundleIdentifier: "test.older")
            let newer = autoProcess(pid: 2042, cpu: 300, risk: .high,
                                    bundleIdentifier: "test.newer")
            let start = Date(timeIntervalSince1970: 15_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, processes: [older], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75,
                               processes: [older], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(90), temperature: 75,
                               processes: [older, newer], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75,
                               processes: [older, newer], settings: settings, isScanning: false)
            let decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(151), temperature: 75,
                                          processes: [older, newer], settings: settings, isScanning: false)
            return decision.kind == .enforce && decision.process?.id == older.id
        }
        check("自动保护永不处理前台项目", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.enforceDuration = 120
            let identity = ProcessIdentity(pid: 2002, startAbstime: 1)
            let process = autoProcess(pid: identity.pid, cpu: 120, risk: .high, identity: identity, foreground: true)
            let start = Date(timeIntervalSince1970: 20_000)
            for offset in stride(from: 0.0, through: 600.0, by: 60.0) {
                let result = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if result.kind == .enforce { return false }
            }
            return true
        }
        check("自动保护不猜杀含辅助进程的应用组", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = testAutoSettings()
            let main = ProcessIdentity(pid: 2007, startAbstime: 1)
            let helper = ProcessIdentity(pid: 2008, startAbstime: 2)
            let process = autoProcess(pid: main.pid, cpu: 150, risk: .high, identity: main,
                                      memberIdentities: [main, helper])
            let start = Date(timeIntervalSince1970: 25_000)
            for offset in stride(from: 0.0, through: 1_800.0, by: 60.0) {
                let result = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            return true
        }
        check("编译与索引任务即使持续高温高 CPU 也不进入自动处置", failures: &failures) {
            let toolNames = ["xcodebuild", "swiftc", "clang", "sourcekit-lsp", "cargo", "rustc", "ninja", "make", "gradle"]
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            for (offset, tool) in toolNames.enumerated() {
                let identity = ProcessIdentity(pid: pid_t(2010 + offset), startAbstime: UInt64(10 + offset))
                let process = autoProcess(pid: identity.pid, cpu: 180, risk: .high, identity: identity,
                                          name: tool, path: "/Users/example/project/\(tool)",
                                          bundleIdentifier: "test.\(tool.replacingOccurrences(of: "-", with: "."))")
                guard LocalKnowledgeBase.isAutomaticProtectionExcluded(name: process.name, path: process.path,
                                                                        bundleIdentifier: process.bundleIdentifier) else {
                    return false
                }
                var engine = AutomaticProtectionEngine()
                let start = Date(timeIntervalSince1970: 55_000 + Double(offset) * 10_000)
                for step in stride(from: 0.0, through: 151.0, by: 30.0) {
                    let result = engine.observeWithFixtureConsent(now: start.addingTimeInterval(step), temperature: 75,
                                                processes: [process], settings: settings, isScanning: false)
                    if result.kind == .countdown || result.kind == .enforce { return false }
                }
            }
            return true
        }
        check("浏览器与沟通工具只允许人工处理不自动结束", failures: &failures) {
            let protectedWorkers = [
                ("Google Chrome Helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", "com.google.Chrome.helper"),
                ("Electron Helper", "/Applications/Example.app/Contents/Frameworks/Electron Helper.app/Contents/MacOS/Electron Helper", "com.example.electron"),
                ("WeChat", "/Applications/WeChat.app/Contents/MacOS/WeChat", "com.tencent.xinWeChat")
            ]
            return protectedWorkers.allSatisfy { worker in
                LocalKnowledgeBase.isAutomaticProtectionExcluded(name: worker.0, path: worker.1,
                                                                  bundleIdentifier: worker.2)
            }
        }
        check("用户已温和降级的进程不会再被自动强杀", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let identity = ProcessIdentity(pid: 2025, startAbstime: 1)
            let process = autoProcess(pid: identity.pid, cpu: 180, risk: .high,
                                      identity: identity, softLimited: true)
            let start = Date(timeIntervalSince1970: 56_000)
            for offset in stride(from: 0.0, through: 180.0, by: 30.0) {
                let result = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                                            processes: [process], settings: settings, isScanning: false)
                if result.kind == .countdown || result.kind == .enforce { return false }
            }
            return true
        }
        check("高 CPU 后台在尚未形成持续证据前仍可手动强制结束", failures: &failures) {
            let watch = autoProcess(pid: 2026, cpu: 80, risk: .watch)
            let justBelow = autoProcess(pid: 2027, cpu: 79.9, risk: .watch)
            let foreground = autoProcess(pid: 2028, cpu: 120, risk: .watch, foreground: true)
            let protected = autoProcess(pid: 2029, cpu: 120, risk: .watch, protected: true)
            return ManualTerminationPolicy.canForceTerminate(watch, isUserProtected: false)
                && !ManualTerminationPolicy.canForceTerminate(justBelow, isUserProtected: false)
                && !ManualTerminationPolicy.canForceTerminate(foreground, isUserProtected: false)
                && !ManualTerminationPolicy.canForceTerminate(protected, isUserProtected: false)
        }
        check("65°C 五分钟只进入异常，不会自动结束", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 300
            settings.enforceDuration = 1200
            let process = autoProcess(pid: 2003, cpu: 100, risk: .elevated)
            let start = Date(timeIntervalSince1970: 30_000)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 600.0, by: 60.0) {
                decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 66,
                    processes: [process], settings: settings, isScanning: false)
            }
            return decision.kind == .anomaly
        }
        check("自动保护不跨进程重启或采样断档累计连续 CPU 证据", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let firstIdentity = ProcessIdentity(pid: 2004, startAbstime: 1)
            let first = autoProcess(pid: firstIdentity.pid, cpu: 100, risk: .high, identity: firstIdentity)
            let start = Date(timeIntervalSince1970: 40_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, processes: [first], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75, processes: [first], settings: settings, isScanning: false)

            // Same bundle, new launch identity: old high-CPU evidence must
            // not turn into an immediate countdown or enforcement.
            let restartedIdentity = ProcessIdentity(pid: 2005, startAbstime: 2)
            let restarted = autoProcess(pid: restartedIdentity.pid, cpu: 100, risk: .high, identity: restartedIdentity)
            let afterRestart = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75,
                                              processes: [restarted], settings: settings, isScanning: false)
            guard afterRestart.kind != .countdown && afterRestart.kind != .enforce else { return false }

            // A delayed frame also breaks the continuous claim even if the
            // process identity itself did not change.
            let afterGap = engine.observeWithFixtureConsent(now: start.addingTimeInterval(300), temperature: 75,
                                          processes: [restarted], settings: settings, isScanning: false)
            return afterGap.kind != .countdown && afterGap.kind != .enforce
        }
        check("自动保护不把同一硬件读数重复算成连续高温", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let process = autoProcess(pid: 2006, cpu: 100, risk: .high)
            let start = Date(timeIntervalSince1970: 50_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, temperatureDate: start,
                               processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75, temperatureDate: start,
                               processes: [process], settings: settings, isScanning: false)
            let stale = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75, temperatureDate: start,
                                       processes: [process], settings: settings, isScanning: false)
            return stale.kind == .blocked
        }
        check("温度证据遇到时钟回退或未来时间戳会清零", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let process = autoProcess(pid: 2008, cpu: 100, risk: .high)
            let start = Date(timeIntervalSince1970: 55_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, temperatureDate: start,
                               processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75,
                               temperatureDate: start.addingTimeInterval(60), processes: [process],
                               settings: settings, isScanning: false)
            // A wall-clock reversal starts a new evidence epoch.
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(-10), temperature: 75,
                               temperatureDate: start.addingTimeInterval(-10), processes: [process],
                               settings: settings, isScanning: false)
            // A producer timestamp far in the future must not be accepted as
            // a fresh 70°C sample while the system clock catches up.
            let future = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75,
                                        temperatureDate: start.addingTimeInterval(3_600),
                                        processes: [process], settings: settings, isScanning: false)
            return future.kind == .blocked
        }
        check("温度采样丢失会清除 CPU 连续证据并在恢复后重新计时", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let process = autoProcess(pid: 2008, cpu: 100, risk: .high)
            let start = Date(timeIntervalSince1970: 57_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75,
                               processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75,
                               processes: [process], settings: settings, isScanning: false)
            let missing = engine.observeWithFixtureConsent(now: start.addingTimeInterval(90), temperature: nil,
                               processes: [process], settings: settings, isScanning: false)
            guard missing.kind == .blocked else { return false }
            let missingProgress = engine.evidence(for: process, now: start.addingTimeInterval(119),
                                                   settings: settings,
                                                   authorizedTargets: Set([AutomaticTerminationGrant(process: process)!]))
            guard missingProgress?.highCPUDuration == 0 && missingProgress?.idleDuration == 0 else { return false }

            // A recovered sensor starts a new thermal and CPU epoch. The old
            // implementation could immediately reach the countdown here by
            // carrying t=0 CPU evidence through the missing read.
            let recovered = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75,
                               processes: [process], settings: settings, isScanning: false)
            guard recovered.kind != .countdown && recovered.kind != .enforce else { return false }
            let fresh = engine.observeWithFixtureConsent(now: start.addingTimeInterval(180), temperature: 75,
                               processes: [process], settings: settings, isScanning: false)
            return fresh.kind != .countdown && fresh.kind != .enforce
        }
        check("自动证据在温度不可用时明确显示只提醒", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = testAutoSettings()
            let process = autoProcess(pid: 2010, cpu: 100, risk: .high)
            let start = Date(timeIntervalSince1970: 58_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: nil,
                               processes: [process], settings: settings, isScanning: false)
            guard let evidence = engine.evidence(for: process, now: start,
                                                  settings: settings,
                                                  authorizedTargets: Set([AutomaticTerminationGrant(process: process)!])) else {
                return false
            }
            return evidence.blockedReason == "温度参考不可用或已过期，自动保护暂停。"
                && evidence.summary.contains("只提醒：温度参考不可用")
        }
        check("自动处置被最终门禁取消后不会错误冷却", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let process = autoProcess(pid: 2009, cpu: 100, risk: .high)
            let start = Date(timeIntervalSince1970: 60_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75, processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75, processes: [process], settings: settings, isScanning: false)
            let enforce = engine.observeWithFixtureConsent(now: start.addingTimeInterval(151), temperature: 75,
                                         processes: [process], settings: settings, isScanning: false)
            guard enforce.kind == .enforce else { return false }
            engine.abortEnforcement(for: process)
            let afterAbort = engine.observeWithFixtureConsent(now: start.addingTimeInterval(211), temperature: 75,
                                            processes: [process], settings: settings, isScanning: false)
            return afterAbort.kind != .blocked && afterAbort.kind != .enforce
        }
        check("倒计时后温度降至 70°C 以下不会继续自动处置", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            var settings = testAutoSettings()
            settings.anomalyDuration = 60
            settings.enforceDuration = 120
            let process = autoProcess(pid: 2019, cpu: 120, risk: .high)
            let start = Date(timeIntervalSince1970: 61_000)
            _ = engine.observeWithFixtureConsent(now: start, temperature: 75, processes: [process], settings: settings, isScanning: false)
            _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(60), temperature: 75, processes: [process], settings: settings, isScanning: false)
            let countdown = engine.observeWithFixtureConsent(now: start.addingTimeInterval(120), temperature: 75,
                                           processes: [process], settings: settings, isScanning: false)
            guard countdown.kind == .countdown else { return false }
            let cooled = engine.observeWithFixtureConsent(now: start.addingTimeInterval(135), temperature: 69,
                                        processes: [process], settings: settings, isScanning: false)
            guard cooled.kind == .anomaly else { return false }
            for offset in stride(from: 151.0, through: 241.0, by: 30.0) {
                let reheated = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                                              processes: [process], settings: settings, isScanning: false)
                if reheated.kind == .countdown || reheated.kind == .enforce { return false }
            }
            let rebuilt = engine.observeWithFixtureConsent(now: start.addingTimeInterval(271), temperature: 75,
                                         processes: [process], settings: settings, isScanning: false)
            return rebuilt.kind == .countdown
        }
        check("新路径即使另获授权也必须重积累 CPU 时长", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = testAutoSettings()
            let start = Date(timeIntervalSince1970: 64_000)
            let original = autoProcess(pid: 2050, cpu: 180, risk: .high)
            let execed = autoProcess(pid: 2050, cpu: 180, risk: .high, path: "/tmp/Replaced.app")
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                                   processes: [original], settings: settings, isScanning: false)
            }
            let changed = engine.observeWithFixtureConsent(now: start.addingTimeInterval(1_200), temperature: 75,
                                         processes: [execed], settings: settings, isScanning: false)
            return changed.kind == .none
        }
        check("同 bundle 内 exec 不能继承已积累的持续 CPU 时长", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = testAutoSettings()
            let start = Date(timeIntervalSince1970: 270_000)
            let original = autoProcess(pid: 1170, cpu: 180, risk: .high)
            let replaced = autoProcess(pid: 1170, cpu: 180, risk: .high,
                executablePath: "/tmp/Worker.app/Contents/MacOS/replacement")
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                _ = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [original], settings: settings, isScanning: false)
            }
            for offset in stride(from: 1_200.0, through: 2_370.0, by: 30.0) {
                let decision = engine.observeWithFixtureConsent(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [replaced], settings: settings, isScanning: false)
                if decision.kind == .countdown || decision.kind == .enforce { return false }
            }
            return engine.observeWithFixtureConsent(now: start.addingTimeInterval(2_400), temperature: 75,
                processes: [replaced], settings: settings, isScanning: false).kind == .countdown
        }
        check("两次采样之间的前台激活事件立即取消目标倒计时并给予使用保护", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let process = autoProcess(pid: 1180, cpu: 180, risk: .high)
            guard let grant = AutomaticTerminationGrant(process: process) else { return false }
            let start = Date(timeIntervalSince1970: 280_000)
            var decision = AutoProtectionDecision(kind: .none, process: nil, reason: "")
            for offset in stride(from: 0.0, through: 1_200.0, by: 30.0) {
                decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false, authorizedTargets: [grant])
            }
            guard decision.kind == .countdown else { return false }
            // The next CPU sample sees this task backgrounded again. Only the
            // workspace event records the intervening foreground use.
            engine.recordForegroundUse(process, at: start.addingTimeInterval(1_210))
            for offset in stride(from: 1_230.0, through: 3_000.0, by: 30.0) {
                decision = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [process], settings: settings, isScanning: false, authorizedTargets: [grant])
                if offset < 1_530 && decision.kind != .none { return false }
                if offset >= 1_530 && (decision.kind != .anomaly || !decision.reason.contains("最近使用保护期")) { return false }
            }
            return true
        }
        check("前台激活只重置自身目标不丢弃无关后台的连续证据", failures: &failures) {
            var engine = AutomaticProtectionEngine()
            let settings = AutoProtectionSettings(mode: .enforce)
            let target = autoProcess(pid: 1190, cpu: 180, risk: .high, bundleIdentifier: "test.target")
            let other = autoProcess(pid: 1191, cpu: 100, risk: .high, bundleIdentifier: "test.other")
            guard let grant = AutomaticTerminationGrant(process: target) else { return false }
            let start = Date(timeIntervalSince1970: 290_000)
            for offset in stride(from: 0.0, through: 1_170.0, by: 30.0) {
                _ = engine.observe(now: start.addingTimeInterval(offset), temperature: 75,
                    processes: [target, other], settings: settings, isScanning: false, authorizedTargets: [grant])
            }
            engine.recordForegroundUse(other, at: start.addingTimeInterval(1_185))
            let countdown = engine.observe(now: start.addingTimeInterval(1_200), temperature: 75,
                processes: [target, other], settings: settings, isScanning: false, authorizedTargets: [grant])
            let enforced = engine.observe(now: start.addingTimeInterval(1_230), temperature: 75,
                processes: [target, other], settings: settings, isScanning: false, authorizedTargets: [grant])
            return countdown.kind == .countdown && countdown.process?.id == target.id
                && enforced.kind == .enforce && enforced.process?.id == target.id
        }
        check("结束身份读取失败必须保守地保持未知", failures: &failures) {
            ActionVerificationTests.run().allSatisfy(\.passed)
        }
        for result in ActionSafetyFaultRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in TopProcessSelectorRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in ForegroundAncestorGateRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in ProtectionSessionGateRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in SamplingTimingsRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        for result in StaticProcessFactsCacheRegression.results() {
            check(result.name, failures: &failures) { result.passed }
        }
        check("静态分类缓存不缓存前台保护名单所有权或调度状态", failures: &failures) {
            var engine = AnalysisEngine()
            let identity = ProcessIdentity(pid: 32109, startAbstime: 9)
            let start = Date(timeIntervalSince1970: 900_000)
            let delta = processDelta(identity: identity, cpu: 90)
            _ = engine.analyze(deltas: [delta], at: start, thermal: .nominal, limited: [], ownPID: getpid())
            let foreground = engine.analyze(deltas: [delta], at: start.addingTimeInterval(30), thermal: .nominal,
                limited: [], ownPID: getpid(), context: AnalysisContext(foregroundPID: identity.pid)).first
            let userProtected = engine.analyze(deltas: [delta], at: start.addingTimeInterval(60), thermal: .nominal,
                limited: [], ownPID: getpid(), context: AnalysisContext(protectedBundleIDs: [delta.path])).first
            let otherUID = ProcessDelta(identity: identity, parentPID: 1, uid: getuid() ^ 1,
                name: delta.name, path: delta.path, cpuPercent: 90, wakeupsPerSecond: 0,
                diskBytesPerSecond: 0, residentBytes: 0, sampleDuration: 30)
            let ownershipChanged = engine.analyze(deltas: [otherUID], at: start.addingTimeInterval(90),
                thermal: .nominal, limited: [], ownPID: getpid()).first
            let restoredOwner = engine.analyze(deltas: [delta], at: start.addingTimeInterval(120),
                thermal: .nominal, limited: [identity], ownPID: getpid()).first
            let stopped = engine.analyze(deltas: [processDelta(identity: identity, cpu: 0)],
                at: start.addingTimeInterval(150), thermal: .nominal, limited: [], ownPID: getpid()).first
            return foreground?.isForeground == true && foreground?.isProtected == true
                && userProtected?.isProtected == true && ownershipChanged?.isSystem == true
                && restoredOwner?.isProtected == false && restoredOwner?.isSoftLimited == true
                && stopped?.isSoftLimited == false && stopped?.cpuPercent == 0 && stopped?.risk == .normal
        }

        if failures.isEmpty {
            print("HeatGuard self-test: \(executed)/\(executed) passed")
            return 0
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("HeatGuard self-test: \(executed - failures.count)/\(executed) passed")
        return 1
    }

    private static func rawSample(
        identity: ProcessIdentity,
        cpu: UInt64,
        wakeups: UInt64 = 0,
        disk: UInt64 = 0
    ) -> RawProcessSample {
        RawProcessSample(
            identity: identity,
            parentPID: 1,
            uid: 501,
            name: "worker",
            path: "/tmp/worker",
            cpuTimeNanoseconds: cpu,
            interruptWakeups: wakeups,
            packageWakeups: 0,
            diskBytes: disk,
            residentBytes: 0
        )
    }

    private static func processDelta(identity: ProcessIdentity, cpu: Double,
                                     path: String = "/tmp/worker", parentPID: pid_t = 1) -> ProcessDelta {
        ProcessDelta(identity: identity, parentPID: parentPID, uid: getuid(), name: "worker", path: path,
                     cpuPercent: cpu, wakeupsPerSecond: 0, diskBytesPerSecond: 0,
                     residentBytes: 0, sampleDuration: 30,
                     wakeupsAvailable: true, diskAvailable: true)
    }

    private static func autoProcess(pid: pid_t, cpu: Double, risk: RiskLevel,
                                    identity: ProcessIdentity? = nil, foreground: Bool = false,
                                    memberIdentities: [ProcessIdentity]? = nil,
                                    name: String = "worker", path: String = "/tmp/Worker.app",
                                    bundleIdentifier: String? = "test.worker",
                                    softLimited: Bool = false, system: Bool = false,
                                    protected: Bool = false,
                                    executablePath: String? = "/tmp/Worker.app/Contents/MacOS/worker",
                                    wakeupsPerSecond: Double = 0,
                                    diskBytesPerSecond: Double = 0,
                                    metricsAvailable: Bool = true) -> AppProcess {
        let id = identity ?? ProcessIdentity(pid: pid, startAbstime: 1)
        return AppProcess(id: id, memberIdentities: memberIdentities ?? [id], pid: pid, parentPID: 1, uid: getuid(),
                          name: name, displayName: "后台 Worker", bundleIdentifier: bundleIdentifier,
                          path: path, cpuPercent: cpu, wakeupsPerSecond: wakeupsPerSecond,
                          diskBytesPerSecond: diskBytesPerSecond, residentBytes: 0, isForeground: foreground,
                          isBackground: !foreground, isSystem: system, isProtected: protected,
                          protectionReason: nil, isSoftLimited: softLimited, risk: risk, confidence: 0.99,
                          evidence: ["test"], recommendation: "test", executablePath: executablePath,
                          wakeupsAvailable: metricsAvailable, diskAvailable: metricsAvailable)
    }

    private static func testAutoSettings() -> AutoProtectionSettings {
        AutoProtectionSettings(mode: .enforce)
    }
}

/// Duration/fault tests explicitly authorize their synthetic task fixtures.
/// Production has no bypass flag. Consent/revocation tests call observe directly
/// with a fixed grant set, so identity changes never gain permission implicitly.
private extension AutomaticProtectionEngine {
    mutating func observeWithFixtureConsent(now: Date, temperature: Double?, temperatureDate: Date? = nil,
        processes: [AppProcess], settings: AutoProtectionSettings, isScanning: Bool) -> AutoProtectionDecision {
        observe(now: now, temperature: temperature, temperatureDate: temperatureDate,
            processes: processes, settings: settings, isScanning: isScanning,
            authorizedTargets: Set(processes.compactMap { AutomaticTerminationGrant(process: $0) }))
    }
}
