import Foundation

/// A one-use, in-memory intent captured by the alert's button closures.
/// Presentation flags are not authority: SwiftUI can hide an alert before
/// invoking its action, and an old callback can outlive stop/cancel/reopen.
struct AutomaticPolicyConfirmation: Identifiable, Equatable, Sendable {
    enum Intent: Equatable, Sendable {
        case enableMode
        case safeIdle
        case changeScope(AutomaticTerminationScope)
        case changeTiming(AutomaticTerminationTiming)
    }

    let id = UUID()
    let intent: Intent
    let settings: AutoProtectionSettings

    var requestedScope: AutomaticTerminationScope {
        switch intent {
        case .enableMode: settings.automaticTerminationScope
        case .safeIdle: .clearIdle
        case .changeScope(let scope): scope
        case .changeTiming: settings.automaticTerminationScope
        }
    }

    var requestedTiming: AutomaticTerminationTiming {
        switch intent {
        case .changeTiming(let timing): timing
        case .safeIdle: .cancelWindow
        case .enableMode, .changeScope: settings.automaticTerminationTiming
        }
    }
}
