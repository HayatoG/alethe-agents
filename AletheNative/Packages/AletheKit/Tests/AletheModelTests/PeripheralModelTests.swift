import AletheFoundation
import Foundation
import Testing
@testable import AletheModel

/// The Phase 7 model (P7-1): preferences, pane and tab fields, toolbar items and the gist sync
/// status, all decoding from files written before they existed.
@Suite struct PeripheralModelTests {
    @Test func preferencesWithoutTheNewKeysDecodeToDefaults() throws {
        let json = #"{"schemaVersion":2,"themeID":"nord","uiScale":1,"alwaysStartUnrestricted":false}"#
        let preferences = try JSONDecoder().decode(PreferencesDocument.self, from: Data(json.utf8))
        #expect(preferences.spotifyClientID == nil && preferences.discordPresence == nil)
        #expect(preferences.router9 == nil && preferences.remote == nil)
        #expect(!preferences.showsDiscordPresence)

        let router9 = preferences.router9Settings
        #expect(!router9.enabled && !router9.autoStart && router9.source == .managed)
        #expect(router9.port == 20128 && !router9.defaultForNewAgents)

        let remote = preferences.remoteSettings
        #expect(remote.maxDevices == 1 && remote.sessionExpirySecs == 3600)
        #expect(remote.readOnly && !remote.allowShellInput && !remote.useTailscale)
    }

    @Test func newPreferencesRoundTripWithoutSecretsOrRemoteEnabled() throws {
        var preferences = PreferencesDocument()
        preferences.spotifyClientID = "client"
        preferences.discordPresence = true
        preferences.router9 = Router9Preferences(enabled: true, source: .external, port: 20200)
        preferences.remote = RemotePreferences(maxDevices: 3, readOnly: false)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(PreferencesDocument.self, from: data) == preferences)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["apiKey", "spotifyClientSecret", "remoteEnabled"] {
            #expect(!text.contains(key), "\(key) is never stored")
        }
    }

    @Test func remoteSettingsAreClamped() throws {
        let decoded = try JSONDecoder().decode(
            RemotePreferences.self, from: Data(#"{"maxDevices":9,"sessionExpirySecs":10}"#.utf8))
        #expect(decoded.maxDevices == 4 && decoded.sessionExpirySecs == 300)
        #expect(decoded.readOnly, "a missing key takes its default")

        var remote = RemotePreferences(maxDevices: 0, sessionExpirySecs: 999_999)
        #expect(remote.maxDevices == 1 && remote.sessionExpirySecs == 86_400)
        remote.maxDevices = 7
        remote.sessionExpirySecs = 60
        #expect(remote.maxDevices == 4 && remote.sessionExpirySecs == 300)
        remote.sessionExpirySecs = 7200
        #expect(remote.sessionExpirySecs == 7200)
    }

    @Test func router9PortAndSourceAreNormalized() throws {
        let decoded = try JSONDecoder().decode(
            Router9Preferences.self, from: Data(#"{"enabled":true,"source":"somewhere","port":70000}"#.utf8))
        #expect(decoded.enabled && decoded.source == .managed && decoded.port == 20128)
        var router9 = Router9Preferences(port: 0)
        #expect(router9.port == 20128)
        router9.port = 8080
        #expect(router9.port == 8080)
        router9.port = -1
        #expect(router9.port == 20128)
    }

    @Test func olderPanesAreNotSharedAndTabsNotRouted() throws {
        var pane = Pane(tabs: [PaneTab(agent: "claude")])
        #expect(!pane.isRemoteShared)
        let data = try JSONEncoder().encode(pane)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["remoteShared"] == nil, "nil is not written")
        object["remoteShared"] = nil
        let decoded = try JSONDecoder().decode(Pane.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.remoteShared == nil && !decoded.isRemoteShared)
        #expect(decoded.tabs.first?.useRouter9 == nil)

        pane.remoteShared = true
        pane.tabs[0].useRouter9 = true
        let shared = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        #expect(shared.isRemoteShared && shared.tabs[0].useRouter9 == true)
        #expect(!Pane(content: .orchestrator).isRemoteShared)
    }

    @Test func peripheralToolbarItems() {
        let preferences = PreferencesDocument()
        #expect(preferences.showsToolbarItem(.sync) && preferences.showsToolbarItem(.remote))
        #expect(!preferences.showsToolbarItem(.router9), "hidden by default, as upstream")
        #expect(ToolbarItemKind(rawValue: "router9") == .router9 && ToolbarItemKind(rawValue: "sync") == .sync)
        #expect(ToolbarItemKind.remote.usageProvider == nil)
    }

    @Test func gistSyncStateNeverHoldsAToken() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-gist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: GistSyncState.fileName)
        #expect(GistSyncState.load(from: url) == GistSyncState(), "a missing file is an empty state")

        let state = GistSyncState(login: "octo", gistID: "abc", lastPushAt: Date(timeIntervalSince1970: 1_767_225_600),
                                  tauriGistID: "def")
        try state.write(to: url)
        #expect(GistSyncState.load(from: url) == state)
        #expect(state.gistURL?.absoluteString == "https://gist.github.com/abc")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(!object.keys.contains { $0.lowercased().contains("token") })

        let locations = DataLocations(root: directory)
        #expect(locations.gistSync(ProfileID(rawValue: "default")).lastPathComponent == "github_sync.json")
    }
}
