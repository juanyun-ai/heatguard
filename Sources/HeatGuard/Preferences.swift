import Foundation

/// The monitor only needs a small property-list-shaped preference surface.
/// Keeping it behind this protocol lets diagnostics use a genuinely in-memory
/// store instead of accidentally touching the installed app's CFPreferences
/// database.
protocol HeatGuardPreferences: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func data(forKey defaultName: String) -> Data?
    func dictionary(forKey defaultName: String) -> [String: Any]?
    func stringArray(forKey defaultName: String) -> [String]?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: HeatGuardPreferences {}

/// Volatile settings used by `--resident-profile`. It deliberately has no
/// filesystem or suite name, so a profile cannot read or write real app prefs.
final class InMemoryPreferences: HeatGuardPreferences {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func dictionary(forKey defaultName: String) -> [String: Any]? {
        values[defaultName] as? [String: Any]
    }
    func stringArray(forKey defaultName: String) -> [String]? {
        values[defaultName] as? [String]
    }
    func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value }
        else { values.removeValue(forKey: defaultName) }
    }
}
