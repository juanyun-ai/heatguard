import AppKit

/// Shared by normal monitoring and the explicit read-only cost diagnostic.
/// Always captures dynamic foreground/application state afresh; never cached.
@MainActor
enum AnalysisContextCapture {
    static func capture(protectedKeys: Set<String>) -> AnalysisContext {
        let front = NSWorkspace.shared.frontmostApplication
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.processIdentifier > 0 }
        var context = AnalysisContext(foregroundPID: front?.processIdentifier,
            foregroundBundleIdentifier: front?.bundleIdentifier,
            protectedBundleIDs: protectedKeys, mainApplicationPIDs: Set(apps.map(\.processIdentifier)))
        context.runningMetadata = Dictionary(apps.map { app in
            (app.processIdentifier, AppMetadata(displayName: app.localizedName ?? "应用",
                bundleIdentifier: app.bundleIdentifier, bundleRoot: app.bundleURL?.path))
        }, uniquingKeysWith: { _, new in new })
        return context
    }
}
