import AppKit
import SwiftUI

@MainActor
protocol AutomaticCountdownPresenting: AnyObject {
    var isPresented: Bool { get }
    func show(process: AppProcess, deadlineUptime: TimeInterval,
              onCancel: @escaping @MainActor () -> Void,
              onOpen: @escaping @MainActor () -> Void)
    func dismiss()
}

/// A small, non-activating danger notice for the destructive 30-second window.
/// Menu-bar agents do not have a Dock window to bounce, so the countdown must
/// remain discoverable even when ordinary notifications are disabled. Ordering
/// this panel front does not activate HeatGuard or steal the user's keyboard
/// focus; the user can explicitly open the dashboard if they want to inspect it.
@MainActor
final class CountdownNoticeController: AutomaticCountdownPresenting {
    private var panel: NSPanel?
    private var timer: Timer?
    private var state: CountdownNoticeState?
    private var attentionRequest: Int?

    var isPresented: Bool { panel != nil }

    func show(process: AppProcess, deadlineUptime: TimeInterval,
              onCancel: @escaping @MainActor () -> Void,
              onOpen: @escaping @MainActor () -> Void) {
        dismiss()
        attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        let state = CountdownNoticeState(
            displayName: process.displayName,
            cpuText: process.cpuPercent.percentText,
            riskText: process.risk.title,
            deadlineUptime: deadlineUptime
        )
        self.state = state
        let content = CountdownNoticeView(state: state, onCancel: { [weak self] in
            self?.dismiss()
            onCancel()
        }, onOpen: { [weak self] in
            // Inspection is an explicit interruption of this incident, not
            // permission to keep a destructive timer running behind a window
            // that might fail to open.
            self?.dismiss()
            onCancel()
            onOpen()
        })
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 188),
            // There is deliberately no closable window affordance: closing
            // the notice must never look like cancelling the action while the
            // automatic token remains valid.
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("heatguard.countdown")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
        position(panel)
        self.panel = panel
        panel.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let state = self.state else { return }
                state.secondsRemaining = max(0, Int(ceil(state.deadlineUptime - ProcessInfo.processInfo.systemUptime)))
                // Keep the warning visible after the 30-second deadline: the
                // next bounded sample still has to re-check temperature,
                // identity and foreground state before any signal is sent.
                if state.secondsRemaining == 0 { state.isVerifying = true; self.timer?.invalidate(); self.timer = nil }
            }
        }
        timer?.tolerance = 0.1
    }

    func dismiss() {
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = max(visible.minX + 20, visible.maxX - panel.frame.width - 20)
        let y = max(visible.minY + 20, visible.maxY - panel.frame.height - 20)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
private final class CountdownNoticeState: ObservableObject {
    let displayName: String
    let cpuText: String
    let riskText: String
    let deadlineUptime: TimeInterval
    @Published var secondsRemaining: Int
    @Published var isVerifying = false

    init(displayName: String, cpuText: String, riskText: String, deadlineUptime: TimeInterval) {
        self.displayName = displayName
        self.cpuText = cpuText
        self.riskText = riskText
        self.deadlineUptime = deadlineUptime
        self.secondsRemaining = max(1, Int(ceil(deadlineUptime - ProcessInfo.processInfo.systemUptime)))
    }
}

private struct CountdownNoticeView: View {
    @ObservedObject var state: CountdownNoticeState
    let onCancel: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text(state.isVerifying ? "温衡：正在复核最后条件" : "温衡：自动保护倒计时")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(state.isVerifying ? "…" : "\(state.secondsRemaining)s")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
            Text("“\(state.displayName)”将被结束")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(state.isVerifying
                ? "倒计时已结束，温衡正在用最新采样复核温度、进程身份和前台状态。条件不再满足就会自动取消。"
                : "后台 CPU \(state.cpuText) · \(state.riskText)。这是最后的取消窗口；未保存工作可能丢失。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消本次") { onCancel() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button("取消并查看") { onOpen() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 360, height: 188, alignment: .topLeading)
    }
}
