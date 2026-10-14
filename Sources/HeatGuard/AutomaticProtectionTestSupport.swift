import Foundation

/// Test doubles replace only input clocks and warning presentation. Policy
/// decisions, action queuing, revocation and native signal verification stay
/// on their production paths. These are never constructed by normal startup.
@MainActor
final class AutomaticProtectionTestClock {
    var date = Date()
    var uptime: TimeInterval = 10_000

    var clock: AutomaticProtectionClock {
        AutomaticProtectionClock(now: { self.date }, uptime: { self.uptime })
    }

    func advance(_ seconds: TimeInterval, uptimeDelta: TimeInterval? = nil) {
        date = date.addingTimeInterval(seconds)
        uptime += uptimeDelta ?? seconds
    }
}

@MainActor
final class RecordingAutomaticCountdown: AutomaticCountdownPresenting {
    private(set) var isPresented = false
    private(set) var presentations = 0
    private(set) var deadlineUptime: TimeInterval?
    private var onCancel: (@MainActor () -> Void)?

    func show(process: AppProcess, deadlineUptime: TimeInterval,
              onCancel: @escaping @MainActor () -> Void,
              onOpen: @escaping @MainActor () -> Void) {
        isPresented = true
        presentations += 1
        self.deadlineUptime = deadlineUptime
        self.onCancel = onCancel
    }

    func dismiss() {
        isPresented = false
        deadlineUptime = nil
        onCancel = nil
    }

    func cancelFromNotice() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}
