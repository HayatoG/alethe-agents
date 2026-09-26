#if DEBUG
import AletheIntegrations
import AletheModel
import Foundation

/// `-AletheUITestSeed` cases for 9router (P7-16); each hook ignores names it does not own.
/// `router9`: turned on, the toolbar pill shown, and a stub managed install whose "node" is
/// `/bin/sh`, so Start runs a harmless sleeping script instead of the real 9router.
/// `router9Fresh`: nothing installed, with the same stubbed lookups (no real `9router` found).
/// `router9Route` (P7-17): as `router9`, keyed, with project `routed` and a stub `claude` that prints
/// `ROUTED <host:port>` when launched with 9router's base URL, else `UNROUTED`, then waits.
/// `router9RouteKeyless`: the same without an API key, so routing is not offered.
extension TestSeeds {
    static let router9RouteSeeds: Set<String> = ["router9Route", "router9RouteKeyless"]

    private static var router9DataRoot: URL {
        URL(filePath: UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp")
    }

    private static var fakeRoutedClaudePath: String { router9DataRoot.appending(path: "fake-claude").path }

    /// Into the (empty) workspace being seeded.
    static func seedRouter9(_ name: String, into doc: inout WorkspaceDocument) {
        guard router9RouteSeeds.contains(name) else { return }
        let project = doc.addProject(name: "routed", folder: "/private/tmp", color: .purple)
        doc.workspace.selectedProjectID = project
    }

    /// Into the preferences, with the workspace seed.
    static func seedRouter9(_ name: String, into preferences: inout PreferencesDocument) {
        guard name == "router9" || router9RouteSeeds.contains(name) else { return }
        preferences.router9 = Router9Preferences(enabled: true)
        preferences.setToolbarItem(.router9, shown: true)
        if router9RouteSeeds.contains(name) {
            writeFakeRoutedClaude()
            var paths = preferences.cliPaths ?? [:]
            paths["claude"] = fakeRoutedClaudePath
            preferences.cliPaths = paths
        }
    }

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedRouter9(_ name: String, environment: AppEnvironment) {
        let routes = router9RouteSeeds.contains(name)
        guard name == "router9" || name == "router9Fresh" || routes,
              let locations = environment.locations, let profile = environment.profileID else { return }
        let paths = Router9Paths(profileDirectory: locations.profileDirectory(profile))
        if name != "router9Fresh" { writeStubRouter9Install(paths) }
        // Through the controller, so it also knows a key is there.
        if name == "router9Route" { environment.router9.saveAPIKey("9r_uitest_route") }
        environment.router9.useStubService(Router9Dependencies(
            resolveExternal: { nil },
            resolveNode: { "/bin/sh" },
            probeVersion: { _ in nil },
            isPortInUse: { _ in false },
            searchDirectories: { [] }
        ))
    }

    /// Reports whether the launch got 9router's variables, never the key itself.
    private static func writeFakeRoutedClaude() {
        let script = #"""
        #!/bin/sh
        if [ -n "$ANTHROPIC_BASE_URL" ] && [ -n "$ANTHROPIC_AUTH_TOKEN" ]; then
          echo "ROUTED ${ANTHROPIC_BASE_URL#http://}"
        else
          echo "UNROUTED"
        fi
        exec /bin/sleep 600
        """#
        try? FileManager.default.createDirectory(at: router9DataRoot, withIntermediateDirectories: true)
        let url = URL(filePath: fakeRoutedClaudePath)
        try? Data(script.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
