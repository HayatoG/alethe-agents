#if DEBUG
import AletheModel
import AletheRemote
import Foundation

/// `-AletheUITestSeed` cases for remote control (P7-12, then P7-20); each hook ignores names it does
/// not own. UI-test launches bind remote control to 127.0.0.1 only (`RemoteControlController`).
///
/// - `remote`: project `remote` with a shared shell pane (`shared`) and a private one (`private`);
///   input allowed; remote control turned on.
/// - `remoteMessage`: the same, then a stub device ("Test Phone") sends a message to the shared tab.
/// - `remoteE2E`: project `remote` with a shared Claude Code pane (`shared`) running `fake-claude` from
///   the data root, and a private shell pane (`private`); one device at most, input allowed, shell
///   input off; remote control turned on. `fake-claude` prints "fake-claude ready", answers each
///   line with "fake-claude got: <line>" and each Ctrl-C with "fake-claude interrupted".
extension TestSeeds {
    static let remoteSeeds: Set<String> = ["remote", "remoteMessage", remoteE2E]
    static let remoteE2E = "remoteE2E"
    static let remoteStubDevice = "Test Phone"

    private static var remoteDataRoot: URL {
        URL(filePath: UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp")
    }

    static var fakeClaudePath: String { remoteDataRoot.appending(path: "fake-claude").path }

    /// Into the (empty) workspace being seeded.
    static func seedRemote(_ name: String, into doc: inout WorkspaceDocument) {
        guard remoteSeeds.contains(name) else { return }
        let project = doc.addProject(name: "remote", folder: remoteDataRoot.path, color: .teal)
        let sharedAgent = name == remoteE2E ? "claude" : "shell"
        if name == remoteE2E { writeFakeClaude() }
        if let shared = doc.addPane(to: project, tab: PaneTab(agent: sharedAgent, title: "shared")) {
            doc.setRemoteShared(shared, true)
        }
        doc.addPane(to: project, tab: PaneTab(agent: "shell", title: "private"))
        doc.workspace.selectedProjectID = project
    }

    /// Into the preferences, with the workspace seed.
    static func seedRemote(_ name: String, into preferences: inout PreferencesDocument) {
        guard remoteSeeds.contains(name) else { return }
        guard name == remoteE2E else {
            preferences.remote = RemotePreferences(maxDevices: 2, readOnly: false, allowShellInput: true)
            return
        }
        preferences.remote = RemotePreferences(maxDevices: 1, readOnly: false, allowShellInput: false)
        var paths = preferences.cliPaths ?? [:]
        paths["claude"] = fakeClaudePath
        preferences.cliPaths = paths
    }

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedRemote(_ name: String, environment: AppEnvironment) {
        guard remoteSeeds.contains(name) else { return }
        let remote = environment.remoteControl
        remote.setEnabled(true)
        guard name == "remoteMessage",
              let tab = environment.workspace?.document.remoteSharedTerminals.first?.tab.id else { return }
        remote.emitForTesting(.message(RemoteMessageEvent(
            terminalID: tab.rawValue, deviceID: 1, deviceName: remoteStubDevice, preview: "hello from the phone")))
    }

    /// A stub Claude Code: its arguments are ignored. A trapped Ctrl-C interrupts `read`, which then
    /// fails, so the loop reads again instead of ending.
    private static func writeFakeClaude() {
        let script = """
        #!/bin/sh
        trap 'echo "fake-claude interrupted"' INT
        echo "fake-claude ready"
        while :; do
          if IFS= read -r line; then echo "fake-claude got: $line"; else sleep 1; fi
        done

        """
        let url = URL(filePath: fakeClaudePath)
        try? FileManager.default.createDirectory(at: remoteDataRoot, withIntermediateDirectories: true)
        try? Data(script.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
#endif
