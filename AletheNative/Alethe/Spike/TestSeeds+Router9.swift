#if DEBUG
import AletheIntegrations
import AletheModel
import Foundation

/// `-AletheUITestSeed` cases for 9router (P7-16); each hook ignores names it does not own.
/// `router9`: turned on, the toolbar pill shown, and a stub managed install whose "node" is
/// `/bin/sh`, so Start runs a harmless sleeping script instead of the real 9router.
/// `router9Fresh`: nothing installed, with the same stubbed lookups (no real `9router` found).
extension TestSeeds {
    /// Into the (empty) workspace being seeded.
    static func seedRouter9(_ name: String, into doc: inout WorkspaceDocument) {}

    /// Into the preferences, with the workspace seed.
    static func seedRouter9(_ name: String, into preferences: inout PreferencesDocument) {
        guard name == "router9" else { return }
        preferences.router9 = Router9Preferences(enabled: true)
        preferences.setToolbarItem(.router9, shown: true)
    }

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedRouter9(_ name: String, environment: AppEnvironment) {
        guard name == "router9" || name == "router9Fresh",
              let locations = environment.locations, let profile = environment.profileID else { return }
        let paths = Router9Paths(profileDirectory: locations.profileDirectory(profile))
        if name == "router9" { writeStubRouter9Install(paths) }
        environment.router9.useStubService(Router9Dependencies(
            resolveExternal: { nil },
            resolveNode: { "/bin/sh" },
            probeVersion: { _ in nil },
            isPortInUse: { _ in false },
            searchDirectories: { [] }
        ))
    }

    /// `node_modules/9router` with the pinned version and a `cli.js` that `/bin/sh` runs as a sleep.
    private static func writeStubRouter9Install(_ paths: Router9Paths) {
        let package = paths.entryScript.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try? Data("{\"name\":\"9router\",\"version\":\"\(Router9.pinnedVersion)\"}".utf8)
            .write(to: package.appending(path: "package.json"))
        try? Data("exec /bin/sleep 600\n".utf8).write(to: paths.entryScript)
    }
}
#endif
