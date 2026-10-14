import AppKit
import Darwin
import SwiftUI

@main
struct HeatGuardApp: App {
    @StateObject private var model: MonitorModel
    @NSApplicationDelegateAdaptor(HeatGuardAppDelegate.self) private var appDelegate

    init() {
        Self.exitIfDuplicateApplication()
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--integration-test") {
            Task { @MainActor in exit(await IntegrationTest.run()) }
            RunLoop.main.run()
            exit(1)
        }
        if CommandLine.arguments.contains("--profile-sampling") {
            Task { @MainActor in exit(await SamplingProfiler.run()) }
            RunLoop.main.run()
            exit(1)
        }
        let uiSmoke = CommandLine.arguments.contains("--ui-smoke")
        if uiSmoke {
            HeatGuardAppDelegate.uiSmokeRequested = true
        }
        let monitor: MonitorModel
        if uiSmoke {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HeatGuard-ui-smoke-\(UUID().uuidString)", isDirectory: true)
            let isolatedPreferences = InMemoryPreferences()
            monitor = MonitorModel(dataDirectory: directory,
                initialAutomaticSettings: AutoProtectionSettings(mode: .advise),
                automaticSettingsWriter: { _ in }, preferences: isolatedPreferences)
            // A smoke run cannot become a forgotten resident process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                HeatGuardAppDelegate.requestQuit()
            }
        } else if let residentProfile = Self.residentProfileSpec() {
            // Never use UserDefaults() here: it is backed by the current
            // application's persistent settings database. A profile must not
            // read or write the installed app's preferences.
            let isolatedPreferences = InMemoryPreferences()
            monitor = MonitorModel(dataDirectory: residentProfile.dataDirectory,
                initialAutomaticSettings: AutoProtectionSettings(mode: .advise),
                automaticSettingsWriter: { _ in }, preferences: isolatedPreferences)
            DispatchQueue.main.asyncAfter(deadline: .now() + residentProfile.duration) {
                HeatGuardAppDelegate.requestQuit()
            }
        } else {
            monitor = MonitorModel()
        }
        HeatGuardAppDelegate.model = monitor
        _model = StateObject(wrappedValue: monitor)
    }

    private struct ResidentProfileSpec {
        let dataDirectory: URL
        let duration: TimeInterval
    }

    /// A local-only resource diagnostic. It deliberately uses a temporary
    /// in-memory preferences and caller-provided data directory, starts advice-only
    /// monitoring, and exits on its own. It cannot send an action or alter the
    /// installed app's history/settings.
    private static func residentProfileSpec() -> ResidentProfileSpec? {
        guard let index = CommandLine.arguments.firstIndex(of: "--resident-profile") else {
            return nil
        }
        guard index + 1 < CommandLine.arguments.count else {
            fputs("--resident-profile 需要临时数据目录\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        let duration: TimeInterval
        if let durationIndex = CommandLine.arguments.firstIndex(of: "--resident-duration"),
           durationIndex + 1 < CommandLine.arguments.count,
           let parsed = Double(CommandLine.arguments[durationIndex + 1]), parsed >= 30, parsed <= 86_400 {
            duration = parsed
        } else {
            duration = 180
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // The caller may have created the directory first. History and
            // action records are private diagnostics, so tighten the leaf
            // directory as well instead of inheriting a world-readable mode.
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
        } catch {
            fputs("无法创建隔离 profile 目录：\(error.localizedDescription)\n", stderr)
            exit(2)
        }
        return ResidentProfileSpec(dataDirectory: directory, duration: duration)
    }

    /// Running the installed copy and a directly opened build artifact at the
    /// same time doubles sampling, menus and automatic-action decisions. Keep
    /// diagnostics usable, but make normal launches converge on one instance
    /// identified by the bundle identifier.
    private static func exitIfDuplicateApplication() {
        let diagnosticArguments = ["--self-test", "--integration-test", "--profile-sampling", "--resident-profile", "--ui-smoke"]
        guard !CommandLine.arguments.contains(where: diagnosticArguments.contains),
              let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier).first(where: {
                $0.processIdentifier != currentPID && !$0.isTerminated
            }) else { return }
        _ = existing.activate(options: [.activateIgnoringOtherApps])
        exit(0)
    }

    var body: some Scene {
        WindowGroup("温衡", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .modifier(DashboardOpenerRegistration(model: model))
        }
        .defaultSize(width: 1040, height: 700)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Label(model.autoProtectionCountdownActive ? "温衡 · 待结束" : "温衡", systemImage: menuBarSymbol)
                .modifier(DashboardOpenerRegistration(model: model))
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        if model.autoProtectionCountdownActive { return "exclamationmark.shield.fill" }
        if let reading = model.temperature {
            switch reading.band {
            case .enforceReference: return "flame.fill"
            case .anomaly: return "thermometer.medium"
            case .normal: break
            }
        }
        switch model.thermal {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious, .critical: return "thermometer.high"
        case .unknown: return "thermometer.variable"
        }
    }
}

/// Scene presentation actions must be read inside the view hierarchy. The
/// menu-bar label is mounted even if the dashboard has never been opened.
/// Copy just the action into the model, not this view (which owns the model).
private struct DashboardOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let model: MonitorModel

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            model.installDashboardOpener { action(id: "dashboard") }
        }
    }
}

@MainActor
final class HeatGuardAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: MonitorModel?
    static var uiSmokeRequested = false
    private static var quitRequested = false
    private var terminating = false
    private var terminationSignal: DispatchSourceSignal?

    static func consumeUISmokeRequest() -> Bool {
        guard uiSmokeRequested else { return false }
        uiSmokeRequested = false
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A normal installer TERM follows the same bounded recovery path as Quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Self.requestQuit() }
        source.resume()
        terminationSignal = source
    }

    /// LSUIElement applications do not get a Dock click to create a window,
    /// but Finder/Launchpad still send the standard reopen event when the
    /// resident instance is opened again. Route that explicit user gesture to
    /// the same dashboard opener used by the menu bar. Do not open a window at
    /// login or during ordinary background activation.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.openDashboard()
        return true
    }

    static func requestQuit() {
        guard !quitRequested else { return }
        quitRequested = true
        // terminateLater spins a nested AppKit modal loop. Calling terminate
        // from a main-dispatch callback would block the very queue needed by
        // the async cleanup. Enter through a run-loop timer, outside that queue.
        let timer = Timer(timeInterval: 0.001, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.quitRequested = true
        guard !terminating else { return .terminateLater }
        guard let model = Self.model else { return .terminateNow }
        terminating = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
