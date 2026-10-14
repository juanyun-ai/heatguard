import Foundation

/// An explicit, in-memory permission for this exact running task. This is
/// deliberately not Codable: a saved preference must never grant permission
/// to a later launch or another executable under the same application name.
/// Permission is required even for a task previously used in the foreground.
/// It is not proof of idleness or an exemption from other safety/duration checks.
struct AutomaticTerminationGrant: Hashable, Sendable {
    let groupKey: String
    let identity: ProcessIdentity
    let path: String
    let bundleIdentifier: String?
    let executablePath: String

    init?(process: AppProcess) {
        guard process.memberIdentities.count == 1,
              process.memberIdentities.first == process.id,
              process.pid == process.id.pid, process.id.pid > 1,
              process.id.startAbstime > 0,
              (process.path as NSString).isAbsolutePath, process.path != "/",
              !process.path.contains("\0"),
              let executablePath = process.executablePath,
              (executablePath as NSString).isAbsolutePath, executablePath != "/",
              !executablePath.contains("\0") else { return nil }
        groupKey = process.groupKey
        identity = process.id
        // Keep the observed spelling: resolving or normalizing the path here
        // could accidentally make different observations share permission.
        path = process.path
        bundleIdentifier = process.bundleIdentifier
        self.executablePath = executablePath
    }

    func matches(process: AppProcess) -> Bool {
        guard let current = Self(process: process) else { return false }
        return self == current
    }
}
