import CoreGraphics
import Foundation

/// A cheap, point-in-time check of public window-server session properties.
/// These fields do not prove that the screen is unlocked. Callers must also
/// retain their independent lock/sleep reasons and cold-start confirmation.
struct ProtectionSessionSnapshot: Equatable, Sendable {
    let onConsole: Bool?
    let loginDone: Bool?
    let anyDisplayAwake: Bool?

    /// Unknown is never permission to perform an automatic destructive action.
    var isInteractive: Bool {
        onConsole == true && loginDone == true && anyDisplayAwake == true
    }

    static func read() -> ProtectionSessionSnapshot {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return ProtectionSessionSnapshot(
            onConsole: boolean(session?[kCGSessionOnConsoleKey]),
            loginDone: boolean(session?[kCGSessionLoginDoneKey]),
            anyDisplayAwake: readDisplayAwake()
        )
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func readDisplayAwake() -> Bool? {
        // The extra slot detects a truncated display list without allocating
        // from an unbounded count or retrying during display reconfiguration.
        let maximumDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maximumDisplays + 1))
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(maximumDisplays + 1, &displays, &count) == .success,
              count <= maximumDisplays else { return nil }
        guard count > 0 else { return false }

        let online = displays.prefix(Int(count))
        // A display disappearing during the read is an uncertain snapshot,
        // not affirmative evidence that its default sleep result is usable.
        guard online.allSatisfy({ $0 != 0 && CGDisplayIsOnline($0) != 0 }) else { return nil }
        return online.contains { CGDisplayIsAsleep($0) == 0 }
    }
}
