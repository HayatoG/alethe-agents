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
extension TestSeeds {
    static let remoteSeeds: Set<String> = ["remote", "remoteMessage"]
    static let remoteStubDevice = "Test Phone"

    /// Into the (empty) workspace being seeded.
    static func seedRemote(_ name: String, into doc: inout WorkspaceDocument) {
        guard remoteSeeds.contains(name) else { return }
        let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
        let project = doc.addProject(name: "remote", folder: root, color: .teal)
        if let shared = doc.addPane(to: project, tab: PaneTab(agent: "shell", title: "shared")) {
            doc.setRemoteShared(shared, true)
        }
        doc.addPane(to: project, tab: PaneTab(agent: "shell", title: "private"))
        doc.workspace.selectedProjectID = project
    }

    /// Into the preferences, with the workspace seed.
    static func seedRemote(_ name: String, into preferences: inout PreferencesDocument) {
        guard remoteSeeds.contains(name) else { return }
        preferences.remote = RemotePreferences(maxDevices: 2, readOnly: false, allowShellInput: true)
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
}
#endif
