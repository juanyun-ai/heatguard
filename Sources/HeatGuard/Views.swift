import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: MonitorModel
    @State private var selection: DashboardSection = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("概览", systemImage: "gauge.with.dots.needle.67percent").tag(DashboardSection.overview)
                Label("进程排查", systemImage: "list.bullet.rectangle").tag(DashboardSection.processes)
                Label("历史趋势", systemImage: "chart.xyaxis.line").tag(DashboardSection.history)
                Label("安全设置", systemImage: "shield.lefthalf.filled").tag(DashboardSection.settings)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selection {
                case .overview: OverviewView()
                case .processes: ProcessListView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 720, minHeight: 560)
        }
        .alert("请求应用正常退出？", isPresented: $model.showTerminationConfirmation, presenting: model.pendingTermination) { process in
            Button("取消", role: .cancel) {}
            Button("请求正常退出") { model.confirmTermination() }
        } message: { process in
            Text("这不会强制结束 \(process.displayName)。应用仍可询问是否保存未完成工作。")
        }
        .alert("强制结束应用？", isPresented: $model.showForceTerminationConfirmation, presenting: model.pendingForceTermination) { process in
            Button("取消", role: .cancel) {}
            Button("确认强制结束", role: .destructive) { model.confirmForceTermination() }
        } message: { process in
            let duration = process.evidence.first(where: { $0.contains("连续高占用") })
                ?? "尚未形成完整连续时长证据"
            let scope = process.memberIdentities.count > 1
                ? "当前只会结束主进程；已合并的辅助进程可能继续运行。"
                : "当前只会结束这个进程。"
            Text("\(process.displayName) 当前 CPU \(process.cpuPercent.percentText)，风险：\(process.risk.title)。\n\(duration)。\n\n\(scope)可能丢失未保存工作或中断任务。温衡会再次核验 PID、启动身份、前台状态和保护名单；任何一项变化都会自动取消。")
        }
        .alert("启用智能自动保护？", isPresented: $model.showAutoProtectionConfirmation,
               presenting: model.pendingAutomaticPolicyConfirmation) { confirmation in
            Button("暂不启用", role: .cancel) { model.cancelAutomaticPolicyConfirmation(confirmation) }
            Button("我了解风险，启用自动结束", role: .destructive) {
                model.confirmAutoProtectionEnable(confirmation)
            }
        } message: { confirmation in
            if confirmation.requestedScope.allowsEphemeralCLI {
                Text("启用后，来自应用或安全临时目录的单一后台目标在硬件温度连续 ≥70°C 达 20 分钟、CPU ≥80%、磁盘/唤醒连续 20 分钟都很低时才可进入 30 秒倒计时；工程目录、用户资料、浏览器、同步、会议和已知关键任务仍只提醒。低 I/O 只能说明“可能空转或纯计算”，不是业务价值证明；重要任务请先加入保护名单。点击“立即停止自动结束”可退回只提醒。")
            } else if confirmation.requestedScope.allowsClearIdle {
                Text("启用后，有可核验应用标识的低 I/O 空转后台在硬件温度连续 ≥70°C 达 20 分钟、CPU ≥80% 后才可进入 30 秒倒计时；无应用标识的命令行项目任务、工程、浏览器、同步、会议和已识别关键任务仍只提醒。\n\n低 I/O 只能说明“可能空转或纯计算”，不是业务价值证明；重要任务请先加入保护名单。点击“立即停止自动结束”可退回只提醒，也可在设置选择安静的“仅观察”。")
            } else {
                Text("启用后，只处理你单独授权本次运行的后台主进程。硬件温度需连续 ≥70°C 达 20 分钟、同一目标 CPU 持续 ≥80%，并且磁盘/唤醒连续 20 分钟都很低；最近 30 分钟使用过的目标仍受保护，然后才会进入 30 秒倒计时。未授权的目标只提醒，曾在前台使用不算授权。授权只绑定身份，不会把正在读写的活动任务当成空转任务。\n\n高 CPU 不能证明任务无用；重要任务请先加入保护名单，未保存工作仍有丢失风险。点击“立即停止自动结束”可退回只提醒，也可在设置选择安静的“仅观察”。")
            }
        }
        .alert("启用安全空转自动保护？", isPresented: $model.showSafeIdleAutomationConfirmation,
               presenting: model.pendingAutomaticPolicyConfirmation) { confirmation in
            Button("暂不启用", role: .cancel) { model.cancelAutomaticPolicyConfirmation(confirmation) }
            Button("我了解风险，启用", role: .destructive) {
                model.confirmSafeIdleAutomation(confirmation)
            }
        } message: { _ in
            Text("启用后，温度连续 ≥70°C 达 20 分钟、后台单一应用 CPU ≥80%、磁盘/唤醒连续很低，且不在前台、最近使用期、保护名单、系统/工程/浏览器/同步/会议/已知重要工具排除范围内的目标，才会进入约 30 秒取消倒计时。65°C 连续 5 分钟只提醒；任何温度、身份、会话或保护信息不确定都会暂停。你可以随时点“立即停止自动结束”。")
        }
        .alert("允许更主动的自动处置范围？", isPresented: $model.showAutomaticScopeConfirmation,
               presenting: model.pendingAutomaticPolicyConfirmation) { confirmation in
            Button("取消更改", role: .cancel) { model.cancelAutomaticPolicyConfirmation(confirmation) }
            Button(confirmation.requestedScope.allowsEphemeralCLI
                ? "我了解风险，启用安全临时命令行"
                : "我了解风险，启用空转自动处置", role: .destructive) {
                model.confirmAutomaticScopeEnable(confirmation)
            }
        } message: { confirmation in
            if confirmation.requestedScope.allowsEphemeralCLI {
                Text("启用后，未单独授权的目标只有在满足全部条件时才可能被强制结束：温度连续 ≥70°C 达 20 分钟、CPU ≥80%、磁盘/唤醒连续 20 分钟都很低、单一可核验进程、非前台/非近期使用，并且不属于工程、浏览器、同步、会议或已知关键任务。无应用标识的命令行还必须来自 /tmp 或系统临时目录；用户资料、工程目录和非临时来源仍只提醒。仍会先给你 30 秒取消机会。低 I/O 不等于无业务价值；请把关键项目加入保护名单。")
            } else {
                Text("启用后，有应用标识的未授权目标只有在满足全部条件时才可能被强制结束：温度连续 ≥70°C 达 20 分钟、CPU ≥80%、连续 20 分钟磁盘/唤醒都很低、单一可核验进程、非前台/非近期使用，并且不属于工程、浏览器、同步、会议或已知关键任务。无应用标识的命令行项目仍只提醒。仍会先给你 30 秒取消机会。低 I/O 不等于无业务价值；请把关键项目加入保护名单。")
            }
        }
        .alert("启用直接自动结束？", isPresented: $model.showAutomaticTimingConfirmation,
               presenting: model.pendingAutomaticPolicyConfirmation) { confirmation in
            Button("保留 30 秒取消窗口", role: .cancel) {
                model.cancelAutomaticTimingConfirmation(confirmation)
            }
            Button("我了解风险，直接结束", role: .destructive) {
                model.confirmAutomaticTimingEnable(confirmation)
            }
        } message: { _ in
            Text("这是高风险选项：满足温度连续 ≥70°C 达 20 分钟、后台 CPU ≥80%、低 I/O 空转连续成立、单一可核验身份、非前台且不在最近使用保护期后，温衡将直接执行强制结束，不再等待 30 秒。系统、保护名单、工程、浏览器、同步、会议和无法核验的任务仍只提醒；最终执行前还会再次核验 PID、启动身份和最新读数。可能丢失未保存工作，建议只对你明确允许自动结束的空转后台启用。")
        }
        .alert("允许本次运行自动结束？", isPresented: $model.showAutomaticPermissionConfirmation,
               presenting: model.pendingAutomaticPermission) { _ in
            Button("取消", role: .cancel) { model.cancelAutomaticPermission() }
            Button("我确认，允许本次运行", role: .destructive) { model.confirmAutomaticPermission() }
        } message: { process in
            Text("目标：\(process.displayName) · PID \(process.pid)\n\(process.executablePath ?? process.path)\n\n请确认这不是正在同步、备份或处理重要工作的任务。授权仅限这个运行实例；仍需开启智能自动保护、连续 20 分钟 ≥70°C、CPU ≥80% 和连续低 I/O 空转证据，并经过 30 秒取消窗口。授权不会绕过前台、最近使用、系统、保护名单或活动 I/O 门槛。\n\n从授权后重新计时，不会立即结束。进程重启、路径变化、失去可核验样本或温衡退出后授权失效；可随时在安全设置撤销。强制结束仍可能丢失未保存工作。")
        }
        .alert("清除温衡的历史记录？", isPresented: $model.showClearHistoryConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除趋势与报告", role: .destructive) { model.clearLocalHistory() }
        } message: {
            Text("只清除温衡保存的趋势、报告与活动记录。保护名单和未完成的调度恢复记录会保留。")
        }
        .sheet(isPresented: $model.showBulkReview) {
            BulkReviewView()
        }
        .sheet(isPresented: $model.showSoftLimitConfirmation) {
            SoftLimitConfirmationView()
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if model.isActionBusy { ProgressView().controlSize(.small) }
                Image(systemName: "shield.checkered").foregroundStyle(.secondary)
                Text(model.statusMessage).font(.caption).lineLimit(3)
                Spacer(minLength: 0)
                Text("仅本机处理 · 不联网").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.bar)
        }
    }
}

enum DashboardSection: Hashable {
    case overview, processes, history, settings
}

struct OverviewView: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    MetricCard(
                        title: "系统热状态",
                        value: thermalValue,
                        detail: thermalDetail,
                        symbol: model.thermal.symbol,
                        tint: thermalTint
                    )
                    MetricCard(
                        title: "整机 CPU",
                        value: model.hostCPUPercent.percentText,
                        detail: String(format: "按整机总容量计算；1 分钟负载 %.2f。", model.loadAverage),
                        symbol: "cpu",
                        tint: model.hostCPUPercent > 80 ? .orange : .blue
                    )
                }

                GroupBox {
                    HStack(spacing: 16) {
                        Label("监控开销", systemImage: "speedometer")
                            .font(.headline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(String(format: "温衡 CPU %.2f%% · 采样 %.1f ms", model.ownCPUPercent, model.lastSampleCostMilliseconds))
                                .monospacedDigit()
                            Text("物理内存足迹 " + model.ownMemoryBytes.memoryText + " · " + model.samplingDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                if let feedback = model.lastPolicyFeedback {
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: feedbackIcon(for: feedback))
                                .foregroundStyle(feedbackIconColor(for: feedback))
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("最近一次后台调度效果")
                                    .font(.headline)
                                Text("\(feedback.displayName) · \(feedback.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let effectSummary = feedback.effectSummary {
                                    Label(effectSummary, systemImage: "checkmark.seal")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if feedback.pending {
                                    if let observation = model.policyCPUObservations[feedback.groupKey] {
                                        Label(observation.progressSummary + " · 这不是 CPU 硬限速。",
                                              systemImage: feedback.interrupted ? "pause.circle" : "timer")
                                            .font(.caption)
                                            .foregroundStyle(feedback.interrupted ? Color.secondary : Color.orange)
                                        ProgressView(value: observation.progressFraction, total: 1)
                                            .progressViewStyle(.linear)
                                            .frame(maxWidth: 220)
                                    } else {
                                        Label("等待下一次有效采样，才能开始处理后观察。",
                                              systemImage: "timer")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Text(feedback.summary)
                                    .font(.callout.monospacedDigit())
                                Text(feedback.explanation)
                                    .font(.caption)
                                    .foregroundStyle(feedbackTextColor(for: feedback))
                                if feedback.remainsHigh,
                                   let process = model.process(for: feedback.groupKey),
                                   model.canForceTerminate(process) {
                                    Button {
                                        model.askToForceTerminate(process)
                                    } label: {
                                        Label("仍高占用，强制结束…", systemImage: "xmark.octagon.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .help("处理后完整观察窗口结束且 CPU 仍高；执行前会再次核验进程身份，可能丢失未保存工作。")
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                    }
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.autoProtectionSettings.mode == .enforce ? "shield.lefthalf.filled" : "eye")
                            .foregroundStyle(model.autoProtectionSettings.mode == .enforce ? .orange : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动保护模式：\(model.autoProtectionSettings.mode.title)")
                                .font(.headline)
                            Text(model.autoProtectionStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if model.autoProtectionSettings.mode == .enforce && model.automaticTerminationGrants.isEmpty {
                                Text(model.autoProtectionSettings.automaticTerminationScope.allowsEphemeralCLI
                                    ? "尚未逐项授权任务：低 I/O 空转应用，以及来自安全临时目录的单进程命令行可能自动结束，其余目标只提醒。"
                                    : model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle
                                        ? "尚未逐项授权任务：只有连续确认的低 I/O 空转应用可能自动结束，其余目标只提醒。"
                                        : "尚未授权任何任务：只提醒，不会自动结束。请在进程卡片核对后允许本次运行。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(model.autoProtectionSettings.automaticTerminationTiming.isImmediate
                                ? "65°C/5分钟只进入异常观察；70°C/20分钟、后台 CPU ≥80% 且连续低 I/O 空转通过全部门禁后直接结束。"
                                : "65°C/5分钟只进入异常观察；70°C/20分钟且后台 CPU ≥80% 才允许进入 30 秒倒计时。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            if model.autoProtectionCountdownActive {
                                Button("取消本次") { model.cancelAutomaticProtection() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            if model.autoProtectionSettings.mode != .enforce
                                || !model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle {
                                Button("启用安全空转自动保护…") {
                                    model.askToEnableSafeIdleAutomation()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.orange)
                                .help("一次确认后启用安全空转范围；关键任务、前台、系统、近期使用和身份不确定的目标仍不会自动结束。")
                            }
                            if model.autoProtectionSettings.mode == .enforce {
                                Button("立即停止自动结束") { model.stopAutomaticTermination() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("停止后保留异常提醒，不会开启已关闭的系统通知；重新启用需再次确认，已发送的结束信号无法撤回。")
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("一键排查")
                                    .font(.title2.weight(.semibold))
                                Text("先连续观察，再解释原因；这次排查本身不会暂停或退出你的应用。")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isScanning {
                                Button("取消", role: .cancel) { model.cancelDiagnostic() }
                            } else {
                                Button {
                                    model.beginDiagnostic()
                                } label: {
                                    Label("开始排查", systemImage: "stethoscope")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        if model.isScanning {
                            ProgressView(value: model.scanProgress)
                        } else {
                            Picker("观察时长", selection: $model.diagnosticDuration) {
                                Text("快速 · 30 秒").tag(30.0)
                                Text("深入 · 2 分钟").tag(120.0)
                            }
                            .pickerStyle(.segmented)
                            Text("快速排查定位主要贡献者；深入排查更适合核对持续后台负载。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                if let report = model.report {
                    ReportSummaryView(report: report)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("当前 CPU 贡献者")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        if !model.actionableProcesses.isEmpty {
                            Button("审查一键处理…") { model.prepareBulkReview() }
                                .buttonStyle(.bordered)
                                .disabled(model.isActionBusy)
                        }
                    }
                    if model.topProcesses.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(model.lastSampleDate == nil ? "正在建立基线" : "暂未发现明显负载").font(.headline)
                            Text("低负载进程可在“进程排查”中查看；不可读进程不代表零占用。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(model.topProcesses.prefix(5)) { process in
                            ProcessRow(process: process)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var thermalTint: Color {
        if let reading = model.temperature {
            switch reading.band {
            case .enforceReference: return .red
            case .anomaly: return .orange
            case .normal: break
            }
        }
        switch model.thermal {
        case .nominal: return .green
        case .fair: return .orange
        case .serious, .critical: return .red
        case .unknown: return .secondary
        }
    }

    private var thermalValue: String {
        guard let reading = model.temperature else { return model.thermal.title }
        return "\(reading.band.title) · \(String(format: "%.1f°C", reading.celsius))"
    }

    private var thermalDetail: String {
        guard let reading = model.temperature else { return model.thermal.explanation }
        let age = max(0, Int(Date().timeIntervalSince(reading.date).rounded(.down)))
        return reading.band.detail + " 系统公共热状态：\(model.thermal.title)。"
            + " 摄氏度为实验性硬件读数（\(reading.source.rawValue)，\(reading.sensorCount) 个传感器，约 \(age) 秒前），不单独触发处理。"
    }

    private func feedbackIcon(for feedback: PolicyFeedback) -> String {
        if feedback.cancelled { return "arrow.uturn.backward.circle" }
        if feedback.interrupted { return "xmark.circle" }
        if feedback.pending { return "clock.arrow.circlepath" }
        return feedback.remainsHigh ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private func feedbackIconColor(for feedback: PolicyFeedback) -> Color {
        if feedback.cancelled || feedback.interrupted { return .secondary }
        return feedback.pending || feedback.remainsHigh ? .orange : .green
    }

    private func feedbackTextColor(for feedback: PolicyFeedback) -> Color {
        if feedback.cancelled || feedback.interrupted { return .secondary }
        return feedback.pending || feedback.remainsHigh ? .orange : .secondary
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }
}

struct ReportSummaryView: View {
    let report: DiagnosticReport

    var body: some View {
        GroupBox("最近一次排查") {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.summary).font(.headline)
                Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(report.duration)) 秒 · 整机 CPU 均值 \(report.hostCPUPercent.percentText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(report.candidates.prefix(3)) { process in
                    HStack {
                        Text(process.displayName)
                        Spacer()
                        Text(process.evidence.contains(where: { $0.contains("仅系统深扫快照") }) ? "约 1 秒快照" : "观察期均值")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(process.cpuPercent.percentText)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                Text(report.coverageNote).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}

struct ProcessRow: View {
    @EnvironmentObject private var model: MonitorModel
    let process: AppProcess

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: process.risk.symbol)
                    .foregroundStyle(riskTint)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(process.displayName).font(.headline)
                        if process.isForeground { Text("前台").font(.caption).foregroundStyle(.secondary) }
                        if process.isSystem { Label("系统保护", systemImage: "lock.shield.fill").font(.caption).foregroundStyle(.secondary) }
                        if process.isProtected || model.isUserProtected(process) { Label("受保护", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        if process.isSoftLimited {
                            let expiry = model.activePolicies
                                .filter { process.memberIdentities.contains($0.identity) }
                                .map(\.expiresAt)
                                .min()
                            Label(expiry.map { "优先级已降低 · 至 " + $0.formatted(date: .omitted, time: .shortened) } ?? "优先级已降低 · 将自动恢复", systemImage: "leaf.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(process.cpuPercent.percentText)
                            .font(.headline.monospacedDigit())
                    }
                    HStack(spacing: 8) {
                        Label("证据强度：\(evidenceLevel)", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(evidenceColor)
                        if let durationEvidence = process.evidence.first(where: { $0.contains("连续高占用") }) {
                            Text(durationEvidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(process.evidence.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(process.recommendation)
                        .font(.callout)
                    if let automaticEvidence = model.automaticEvidence(for: process),
                       automaticEvidence.isRelevant {
                        Label(automaticEvidence.summary,
                              systemImage: automaticEvidence.blockedReason == nil
                                  ? "shield.lefthalf.filled" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(automaticEvidence.blockedReason == nil ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { primaryActions }
                            VStack(alignment: .leading, spacing: 8) { primaryActions }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { secondaryActions }
                            VStack(alignment: .leading, spacing: 8) { secondaryActions }
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isActionBusy)
                    if let grant = AutomaticTerminationGrant(process: process), model.hasAutomaticPermission(process) {
                        HStack {
                            Label("本次运行已允许自动结束", systemImage: "checkmark.shield")
                                .foregroundStyle(.orange)
                            Button("撤销授权") { model.removeAutomaticPermission(grant) }
                        }
                        .font(.caption)
                    } else if model.canAllowAutomaticTermination(process) {
                        Button("允许本次运行自动结束…") { model.askToAllowAutomaticTermination(process) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(model.isActionBusy)
                    }
                    if process.isSoftLimited, let evidence = model.softLimitEvidence(for: process) {
                        Text(evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let observation = model.softLimitObservation(for: process) {
                            Label(observation.progressSummary,
                                  systemImage: observation.isComplete ? "checkmark.circle" : "timer")
                                .font(.caption)
                                .foregroundStyle(observation.isComplete ? Color.secondary : Color.orange)
                            ProgressView(value: observation.progressFraction, total: 1)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 150)
                            Text(observation.summary)
                                .font(.callout.monospacedDigit())
                            Text(observation.explanation)
                                .font(.caption)
                                .foregroundStyle(observation.remainsHigh ? .orange : .secondary)
                            if observation.isComplete, observation.remainsHigh,
                               model.canForceTerminate(process) {
                                Button {
                                    model.askToForceTerminate(process)
                                } label: {
                                    Label("仍高占用，强制结束…", systemImage: "xmark.octagon.fill")
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .help("已完成约 1 分钟观察且 CPU 仍高；执行前仍会二次确认进程身份，可能丢失未保存工作。")
                            }
                        }
                        if process.cpuPercent >= 80 {
                            Text("降低优先级只在资源争用时生效；当前仍高占用时，可先切换确认任务，再使用“强制结束”。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var manualActionsAllowed: Bool {
        !process.isSystem && !process.isProtected && !process.isForeground && !model.isUserProtected(process)
    }

    @ViewBuilder private var primaryActions: some View {
        Button("切换过去") { model.activate(process) }
        if manualActionsAllowed {
            Button("正常退出…") { model.askToTerminate(process) }
        }
        if model.canForceTerminate(process) {
            Button { model.askToForceTerminate(process) } label: {
                Label(process.memberIdentities.count > 1 ? "强制结束主进程…" : "强制结束…",
                      systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        if process.isSoftLimited {
            Button("撤销优先级调整") { model.restore(process) }
        } else if manualActionsAllowed && (process.cpuPercent >= 20 || process.risk >= .watch) {
            Button("降低调度优先级（10 分钟）") { model.askToSoften(process) }
                .help("调用 macOS 后台调度，让目标在 CPU 争用时让步；不是 CPU 硬限速。执行后会显示优先级回读、前后 CPU 变化和下一步强制结束入口。")
        }
        if !process.isSystem && !process.isProtected
            && !model.isUserProtected(process) && !process.protectionKey.isEmpty {
            Button("始终保护") { model.protect(process) }
                .buttonStyle(.borderless)
        }
        Button("隐藏 1 小时") { model.ignore(process) }
            .buttonStyle(.borderless)
    }

    private var riskTint: Color {
        switch process.risk {
        case .normal: .green
        case .watch: .blue
        case .elevated: .orange
        case .high: .red
        }
    }

    private var evidenceLevel: String {
        if process.confidence >= 0.75 { return "高" }
        if process.confidence >= 0.45 { return "中" }
        return "低"
    }

    private var evidenceColor: Color {
        if process.confidence >= 0.75 { return .green }
        if process.confidence >= 0.45 { return .orange }
        return .secondary
    }
}

struct ProcessListView: View {
    @EnvironmentObject private var model: MonitorModel
    @State private var search = ""
    @State private var showLowLoad = false

    private var visibleProcesses: [AppProcess] {
        let source = showLowLoad ? model.processes.sorted { $0.cpuPercent > $1.cpuPercent } : model.topProcesses
        return source.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
            || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("进程排查").font(.largeTitle.weight(.semibold))
                    Text("100% 表示占满一个逻辑核心；多线程应用可以超过 100%。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Button("立即采样") { model.sampleNowFromUI() }
                    Button("一键排查") { model.beginDiagnostic() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isScanning)
                }
            }
            HStack {
                TextField("搜索应用或进程", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("显示低负载", isOn: $showLowLoad).toggleStyle(.checkbox)
            }
            Text(model.monitoringCoverageText).font(.caption).foregroundStyle(.secondary)
            List(visibleProcesses) { process in
                ProcessRow(process: process)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
        .padding(24)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("历史趋势").font(.largeTitle.weight(.semibold))
            Text("仅保存在本机；保留 24 小时的每分钟采样峰值、最近 12 份报告和最多 400 天的保守热暴露账本。峰值不是整分钟均值。")
                .foregroundStyle(.secondary)
            HStack {
                Text(model.monitoringCoverageText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.report != nil {
                    Button("导出所选报告…") { model.saveLatestReport() }
                }
                Button("清除本地历史…", role: .destructive) { model.showClearHistoryConfirmation = true }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("长期热暴露（本机）", systemImage: "heart.text.square")
                            .font(.headline)
                        Spacer()
                        if let latest = model.thermalExposure.last {
                            Text(latest.day.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.thermalExposure.isEmpty {
                        Text("等待两次连续有效温度采样后开始累计；传感器缺失或采样间隔过长不会补算。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        let recent = Array(model.thermalExposure.suffix(14))
                        let recent65 = recent.reduce(0) { $0 + $1.above65Minutes }
                        let recent70 = recent.reduce(0) { $0 + $1.above70Minutes }
                        HStack(spacing: 18) {
                            Label(String(format: "近 %d 天 ≥65°C %.0f 分钟", recent.count, recent65), systemImage: "thermometer.medium")
                                .foregroundStyle(.orange)
                            Label(String(format: "≥70°C %.0f 分钟", recent70), systemImage: "flame.fill")
                                .foregroundStyle(.red)
                        }
                        .font(.callout.monospacedDigit())
                        Chart(recent) { day in
                            BarMark(x: .value("日期", day.day), y: .value("≥65°C", day.above65Minutes))
                                .foregroundStyle(.orange.opacity(0.75))
                            BarMark(x: .value("日期", day.day), y: .value("≥70°C", day.above70Minutes))
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .chartYAxisLabel("分钟")
                        .frame(height: 150)
                        Text("这是保守暴露统计，不是硬件寿命预测：只有连续有效样本之间的区间才计入，不能替代散热、通风和人工维护。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            GroupBox {
                Chart(model.history) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("整机 CPU", point.cpuPercent)
                    )
                    .foregroundStyle(.blue)
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("整机 CPU", point.cpuPercent)
                    )
                    .foregroundStyle(.blue.opacity(0.12))
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("整机 CPU % · 每分钟采样峰值")
                .frame(height: 230)
                .padding(12)
            }
            let temperatureHistory = model.history.filter { $0.temperature != nil }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("硬件温度趋势", systemImage: "thermometer.medium")
                            .font(.headline)
                        Spacer()
                        if let latest = temperatureHistory.last?.temperature {
                            Text(String(format: "最近 %.1f°C", latest))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if temperatureHistory.isEmpty {
                        Label("当前机型没有可用的温度历史；CPU 与热状态历史仍可用。", systemImage: "questionmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Chart {
                            ForEach(temperatureHistory) { point in
                                if let temperature = point.temperature {
                                    LineMark(
                                        x: .value("时间", point.date),
                                        y: .value("硬件温度", temperature)
                                    )
                                    .foregroundStyle(.orange)
                                    AreaMark(
                                        x: .value("时间", point.date),
                                        y: .value("硬件温度", temperature)
                                    )
                                    .foregroundStyle(.orange.opacity(0.12))
                                }
                            }
                            RuleMark(y: .value("异常观察线", 65))
                                .foregroundStyle(.orange.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .leading) {
                                    Text("65°C 观察")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            RuleMark(y: .value("执行前提", 70))
                                .foregroundStyle(.red.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Text("70°C 执行前提")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxisLabel("硬件温度 °C · 每分钟采样峰值")
                        .frame(height: 230)
                    }
                }
                .padding(12)
            }
            if !model.reportHistory.isEmpty {
                GroupBox("排查报告") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.reportHistory.reversed()) { item in
                            Button { model.selectReport(item) } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: model.report?.id == item.id ? "checkmark.circle.fill" : "doc.text")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                        Text(item.summary).lineLimit(2)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(8)
                }
                if let selected = model.report { ReportSummaryView(report: selected) }
            }
            if !model.events.isEmpty {
                GroupBox("最近活动") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.events.suffix(6).reversed()) { event in
                            HStack {
                                Text(event.date, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
          }
          .padding(24)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        Form {
            Section("常驻") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("热压力严重时通知我", isOn: $model.notificationsEnabled)
                    .onChange(of: model.notificationsEnabled) { enabled in
                        if enabled { model.requestNotificationPermission() }
                    }
                Picker("采样策略", selection: $model.samplingMode) {
                    ForEach(SamplingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(model.samplingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("安全边界") {
                Label(model.autoProtectionSettings.mode == .enforce
                    ? "智能自动保护已启用：仍需满足全部门槛"
                    : "默认只观察和解释，不自动结束任何应用",
                      systemImage: "shield.checkered")
                Label("后台调度可撤销；手动结束需单独确认", systemImage: "arrow.uturn.backward.circle")
                Text("后台调度是优先级提示，不是 CPU 硬限速；没有其他任务争用时，CPU 和温度可能几乎不变。点击后温衡会一次性回读 macOS 的 Darwin 后台线程状态，并把‘已进入后台调度’或‘无法确认’显示在效果卡里；读回失败或已有非标准策略会主动跳过，避免覆盖其他工具。撤销会恢复系统标准调度；每次处理前都会再次核对 PID 启动身份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("前台、系统及已识别的会议和录制应用受保护", systemImage: "lock.shield")
                Text("保护也覆盖可核验的后台子任务。来自 IDE、终端及已知重要工具的子进程只提醒，不自动结束；无法完整核验父进程关系时不处理。")
                    .font(.caption).foregroundStyle(.secondary)
                Label("不修改风扇、不删除缓存、不上传数据", systemImage: "hand.raised.fill")
            }
            Section("智能自动保护") {
                Picker("保护策略", selection: Binding(
                    get: { model.autoProtectionSettings.mode },
                    set: { model.setAutoProtectionMode($0) }
                )) {
                    ForEach(AutoProtectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(model.autoProtectionSettings.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("自动处置范围", selection: Binding(
                    get: { model.autoProtectionSettings.automaticTerminationScope },
                    set: { model.setAutomaticTerminationScope($0) }
                )) {
                    ForEach(AutomaticTerminationScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(model.autoProtectionSettings.automaticTerminationScope.detail)
                    .font(.caption)
                    .foregroundStyle(model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle ? .orange : .secondary)
                Picker("自动结束方式", selection: Binding(
                    get: { model.autoProtectionSettings.automaticTerminationTiming },
                    set: { model.setAutomaticTerminationTiming($0) }
                )) {
                    ForEach(AutomaticTerminationTiming.allCases, id: \.self) { timing in
                        Text(timing.title).tag(timing)
                    }
                }
                Text(model.autoProtectionSettings.automaticTerminationTiming.detail)
                    .font(.caption)
                    .foregroundStyle(model.autoProtectionSettings.automaticTerminationTiming.isImmediate ? .red : .secondary)
                if model.autoProtectionSettings.mode != .enforce
                    || !model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle {
                    Button {
                        model.askToEnableSafeIdleAutomation()
                    } label: {
                        Label("启用安全空转自动保护…", systemImage: "shield.lefthalf.filled")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Text("这是一次确认的快捷预设：普通后台仍只采样，只有达到 70°C/20 分钟、CPU≥80%、低 I/O 且通过所有保护门槛的单一应用才会进入 30 秒取消窗口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.autoProtectionSettings.mode == .enforce {
                    HStack {
                        if !model.automaticSessionConfirmed {
                            Button("确认本次会话，开始自动保护") { model.confirmAutomaticProtectionForSession() }
                            Label("本次会话尚未确认，自动结束已暂停", systemImage: "pause.circle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        } else {
                            Label("本次会话已确认，正在按门槛累计证据", systemImage: "checkmark.shield")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Button("立即停止自动结束") { model.stopAutomaticTermination() }
                            .help("停止后保留异常提醒，不会开启已关闭的系统通知；重新启用需再次确认，已发送的结束信号无法撤回。")
                    }
                }
                Text("冷启动时无法可靠判断屏幕是否已锁定，因此自动结束需在本次会话点击确认，或收到后续解锁事件；普通监测不受该确认影响。不会用自动打开窗口冒充你的确认。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.autoProtectionSettings.automaticTerminationTiming.isImmediate
                    ? "异常观察：硬件温度连续 5 分钟 ≥ 65°C 即标记为热异常参考；若能定位到同一后台持续高 CPU，会列出具体候选。自动保护：硬件温度连续 20 分钟 ≥ 70°C，且后台 CPU ≥ 80%，通过全部空转和保护门槛后直接结束。"
                    : "异常观察：硬件温度连续 5 分钟 ≥ 65°C 即标记为热异常参考；若能定位到同一后台持续高 CPU，会列出具体候选。自动保护：硬件温度连续 20 分钟 ≥ 70°C，且后台 CPU ≥ 80%，通过全部空转和保护门槛后再给 30 秒取消机会。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.autoProtectionSettings.automaticTerminationScope.allowsEphemeralCLI
                    ? "前台、系统、保护名单、最近 30 分钟使用过的应用都不会被自动结束。未授权应用后台只有在连续低 I/O 空转证据成立时才可能自动结束；无应用标识的目标还必须来自 /tmp 或系统临时目录。工程目录、用户资料、浏览器、同步、会议和已知关键任务仍只提醒。高 CPU 不能单独证明空转，重要任务请加入保护名单。"
                    : model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle
                        ? "前台、系统、保护名单、最近 30 分钟使用过的应用都不会被自动结束。未授权应用后台只有在连续低 I/O 空转证据成立时才可能自动结束；无应用标识的命令行项目、工程、浏览器、同步、会议和已知关键任务仍只提醒。高 CPU 不能单独证明空转，重要任务请加入保护名单。"
                        : "前台、系统、保护名单、最近 30 分钟使用过的应用都不会被自动结束。所有未授权后台都只提醒，包括曾在前台用过的应用；可在进程卡片单独允许本次运行，重启或路径变化必须重新授权。高 CPU 不能证明空转，重要任务请加入保护名单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(model.autoProtectionStatus, systemImage: model.autoProtectionSettings.mode == .enforce ? "shield.lefthalf.filled" : "eye")
                    .font(.callout)
            }
            Section("本次运行的自动结束授权") {
                if model.automaticTerminationGrants.isEmpty {
                    Text(model.autoProtectionSettings.automaticTerminationScope.allowsClearIdle
                        ? "尚未逐项授权任务；低 I/O 空转范围仍可能按安全门槛自动处置，其余目标可在进程卡片核对后单独授权。"
                        : "尚未授权任何任务，自动结束不会执行。可在进程卡片核对目标后点“允许本次运行自动结束”。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.automaticTerminationGrants.keys.sorted { $0.identity.pid < $1.identity.pid }, id: \.self) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.automaticTerminationGrants[grant] ?? "已授权后台")
                            Text("PID \(grant.identity.pid) · " + grant.executablePath)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("撤销授权") { model.removeAutomaticPermission(grant) }
                    }
                }
                if !model.automaticTerminationGrants.isEmpty {
                    Button("撤销所有本次授权") { model.removeAllAutomaticPermissions() }
                }
                Text("只记在内存中，不按名称或路径永久放行；授权不代表正在倒计时，也不会替你开启智能自动保护。保护名单始终优先。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("处理与恢复") {
                if model.activePolicies.isEmpty {
                    Text("没有待恢复的调度操作。").foregroundStyle(.secondary)
                }
                ForEach(model.activePolicies) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.displayName)
                            Text("PID \(entry.identity.pid) · \(entry.expiresAt <= Date() ? "待恢复 / 会重试" : "计划恢复 " + entry.expiresAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let evidence = model.policyEffectEvidence[entry.identity]?.summary {
                                Text(evidence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let observation = model.policyCPUObservations.values.first(where: { $0.appliedIdentities.contains(entry.identity) }) {
                                Label(observation.progressSummary,
                                      systemImage: observation.isComplete ? "checkmark.circle" : "timer")
                                    .font(.caption)
                                    .foregroundStyle(observation.isComplete ? Color.secondary : Color.orange)
                                ProgressView(value: observation.progressFraction, total: 1)
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 150)
                                Text(observation.summary).font(.caption).monospacedDigit()
                                Text(observation.explanation).font(.caption)
                                    .foregroundStyle(observation.remainsHigh ? .orange : .secondary)
                            }
                        }
                        Spacer()
                        Button("立即恢复") { model.restorePolicy(entry) }.disabled(model.isActionBusy)
                    }
                }
                Text("恢复失败会保留记录并低频重试。温衡正常退出时会尝试恢复；异常退出后将在下次启动继续核验。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("我的保护名单") {
                if model.protectedApps.isEmpty {
                    Text("在进程卡片点“始终保护”，把不希望被处理的工作软件加入这里。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.protectedApps.keys.sorted(), id: \.self) { key in
                    HStack {
                        Label(model.protectedApps[key] ?? key, systemImage: "lock.fill")
                        Spacer()
                        Button("移除自定义保护") { model.removeProtection(key) }
                    }
                }
                Button("恢复所有暂时隐藏的应用") { model.resetIgnored() }
            }
            Section("关于温度") {
                Text("以 macOS 热状态、持续 CPU 和前后台证据判断风险。可用时显示只读的实验性 CPU 温度；某些机型或系统版本可能不支持，不影响基础排查。单个摄氏读数不能证明应用异常。")
                    .foregroundStyle(.secondary)
            }
            Section("离线与隐私") {
                Text("所有采样、规则和建议都在本机运行，无账号、无云端模型。仅保存应用名称、程序路径及资源指标；不读取文档内容、命令行参数、窗口标题或浏览历史。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}

struct SoftLimitConfirmationView: View {
    @EnvironmentObject private var model: MonitorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("确认降低调度优先级", systemImage: "leaf.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            if let process = model.pendingSoftLimit {
                Text(process.displayName).font(.headline)
                Text("把它放到 macOS 的后台调度等级约 10 分钟；不会暂停、退出或修改文件。它只在 CPU 争用时让步，不是 CPU 硬限速，不保证 CPU 或温度立刻下降；可能延长下载、同步、编译或导出，请确认不是你正在等待的任务。执行后会显示系统优先级回读、CPU 前后变化和温度是否同步变化；温度采样不完整时会明确显示不能比较。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("温衡运行期间，目标回前台或到期会尝试恢复；可随时到“安全设置 → 处理与恢复”撤销。恢复的是系统标准调度；已有非标准策略或回读不可用的目标不会被温衡覆盖。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if process.isSystem {
                    Label("这是系统进程，温衡不会对它执行调度或退出操作。", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                } else if process.isProtected || process.isForeground {
                    Label("该目标已被保护，不能执行。", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确认并降低优先级") { model.confirmSoften() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(model.isActionBusy || model.pendingSoftLimit == nil
                              || model.pendingSoftLimit?.isSystem == true
                              || model.pendingSoftLimit?.isProtected == true
                              || model.pendingSoftLimit?.isForeground == true)
            }
        }
        .padding(24)
        .frame(width: 560, height: 350)
    }
}

struct BulkReviewView: View {
    @EnvironmentObject private var model: MonitorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("审查一键处理").font(.title.weight(.semibold))
            Text("只处理下列已观察到持续负载的候选应用，约 10 分钟。不会退出、暂停或修改文件。名单已固定；执行前会重新核验前台状态和进程身份。")
                .foregroundStyle(.secondary)
            Text("执行前请确认这些任务不是你正在等待的编译、同步、导出或备份。")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(model.bulkTargets) { process in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(process.displayName).font(.headline)
                        Text("CPU \(process.cpuPercent.percentText) · \(process.recommendation)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("执行可撤销处理") { model.applySafeBulkActions() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.bulkTargets.isEmpty || model.isActionBusy)
            }
        }
        .padding(24)
        .frame(width: 620, height: 420)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reading = model.temperature {
                Label {
                    Text(String(format: "硬件温度：%@ · %.1f°C", reading.band.title, reading.celsius))
                } icon: {
                    Image(systemName: reading.band == .enforceReference
                        ? "flame.fill"
                        : reading.band == .anomaly ? "thermometer.medium" : "checkmark.circle.fill")
                }
                .foregroundStyle(reading.band == .enforceReference
                    ? Color.red
                    : reading.band == .anomaly ? Color.orange : Color.primary)
                Text("公共热状态：\(model.thermal.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("硬件温度：不可用", systemImage: "thermometer.transmission")
                    .foregroundStyle(.secondary)
                Text("公共热状态：\(model.thermal.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("整机 CPU：\(model.hostCPUPercent.percentText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let first = model.topProcesses.first {
                Text("主要贡献者：\(first.displayName) \(first.cpuPercent.percentText)")
                    .font(.caption)
            }
            Label(model.autoProtectionStatus,
                  systemImage: model.autoProtectionCountdownActive ? "timer" : "shield.checkered")
                .font(.caption)
                .foregroundStyle(model.autoProtectionCountdownActive ? .orange : .secondary)
                .lineLimit(2)
            if model.autoProtectionCountdownActive {
                Button("取消本次自动保护") { model.cancelAutomaticProtection() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if model.autoProtectionSettings.mode == .enforce {
                if model.automaticTerminationGrants.isEmpty {
                    Text(model.autoProtectionSettings.automaticTerminationScope.emptyGrantSummary)
                        .font(.caption)
                }
                Button("立即停止自动结束") { model.stopAutomaticTermination() }
                    .help("停止后保留异常提醒，不会开启已关闭的系统通知；重新启用需再次确认，已发送的结束信号无法撤回。")
            }
            if !model.activePolicies.isEmpty {
                Text("待恢复操作：\(model.activePolicies.count) 个进程")
                    .font(.caption)
            }
            Divider()
            Button("打开温衡") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(model.isScanning ? "正在排查…" : "一键排查") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                model.beginDiagnostic()
            }
            .disabled(model.isScanning)
            Divider()
            Button("退出温衡") { HeatGuardAppDelegate.requestQuit() }
        }
        .padding(4)
        .frame(width: 260)
        .onAppear {
            guard HeatGuardAppDelegate.consumeUISmokeRequest() else { return }
            // MenuBarExtra has mounted the scene action at this point. Open
            // exactly one dashboard for the isolated UI smoke run; normal
            // resident launches remain menu-bar-only until the user clicks.
            DispatchQueue.main.async {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
