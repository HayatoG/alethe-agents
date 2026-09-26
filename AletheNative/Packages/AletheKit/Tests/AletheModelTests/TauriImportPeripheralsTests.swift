import AletheFoundation
import Foundation
import Testing
@testable import AletheModel

/// The Phase 7 part of the Tauri import (P7-1) over an anonymized v9 profile folder: preferences,
/// remote sharing, 9router routing, and the plaintext secrets reported for the Keychain and never
/// written to a profile file.
@Suite struct TauriImportPeripheralsTests {
    private static let context = TauriImport.Context(agents: ["claude", "codex", "shell"], themes: ["elite-indigo"])
    /// Every secret value in the fixture folder.
    private static let secretValues = [
        "FIXTURE-SPOTIFY-SECRET-0001", "FIXTURE-ROUTER9-KEY-0002", "FIXTURE-SPOTIFY-ACCESS-0003",
        "FIXTURE-SPOTIFY-REFRESH-0004", "FIXTURE-GITHUB-TOKEN-0005",
    ]

    private func folder() throws -> URL {
        let file = try #require(Bundle.module.url(forResource: "projects", withExtension: "json",
                                                  subdirectory: "Fixtures/TauriPeripherals"))
        return file.deletingLastPathComponent()
    }

    private func imported(context: TauriImport.Context = context) throws
        -> (WorkspaceDocument, PreferencesDocument, TauriImport.Report, TauriImport.Secrets) {
        let projects = try folder().appending(path: "projects.json")
        let file = try TauriImport.File(data: Data(contentsOf: projects))
        let companions = TauriImport.Companions.beside(projects)
        var workspace = WorkspaceDocument()
        var preferences = PreferencesDocument()
        let report = TauriImport.apply(file, companions: companions, to: &workspace, preferences: &preferences,
                                       context: context)
        return (workspace, preferences, report, TauriImport.secrets(in: file, companions: companions, context: context))
    }

    @Test func mapsPeripheralPreferences() throws {
        let (_, prefs, report, _) = try imported()
        #expect(prefs.spotifyClientID == "fixture-spotify-client-id", "trimmed")
        #expect(prefs.discordPresence == true)
        #expect(prefs.router9 == Router9Preferences(enabled: true, autoStart: true, source: .external, port: 20200,
                                                   defaultForNewAgents: true))
        #expect(prefs.remote == RemotePreferences(maxDevices: 4, sessionExpirySecs: 300, readOnly: false,
                                                 allowShellInput: true, useTailscale: true), "clamped")
        #expect(!prefs.showsToolbarItem(.sync) && prefs.showsToolbarItem(.router9))
        #expect(report.preferences == [.integrations, .router9, .remote, .toolbar])
    }

    @Test func mapsRemoteSharingAndRouting() throws {
        let (workspace, _, _, _) = try imported()
        let project = try #require(workspace.projects.first)
        let shared = Dictionary(uniqueKeysWithValues: project.panes.map { ($0.id.rawValue, $0.remoteShared) })
        #expect(shared["t-shared"] == true)
        #expect(shared["t-excluded"] == .some(nil), "remoteExcluded opts out")
        #expect(shared["t-legacy"] == true, "upstream's v8 migration: not excluded means shared")
        #expect(shared["t-private"] == .some(nil), "an explicit remoteShared wins")
        let tabs = project.panes.flatMap(\.tabs)
        #expect(tabs.filter { $0.useRouter9 == true }.map(\.agent) == ["claude"])
    }

    @Test func reportsSecretsWithTheirValues() throws {
        let (_, _, report, secrets) = try imported()
        #expect(report.secrets == Set(KeychainItem.allCases))
        #expect(Set(secrets.values.keys) == report.secrets)
        func text(_ item: KeychainItem) -> String? { secrets.values[item].map { String(decoding: $0, as: UTF8.self) } }
        #expect(text(.spotifyClientSecret) == "FIXTURE-SPOTIFY-SECRET-0001")
        #expect(text(.router9APIKey) == "FIXTURE-ROUTER9-KEY-0002")
        #expect(text(.githubToken) == "FIXTURE-GITHUB-TOKEN-0005")
        let tokens = try JSONDecoder().decode(SpotifyTokens.self, from: try #require(secrets.values[.spotifyTokens]))
        #expect(tokens == SpotifyTokens(accessToken: "FIXTURE-SPOTIFY-ACCESS-0003",
                                        refreshToken: "FIXTURE-SPOTIFY-REFRESH-0004",
                                        expiresAt: Date(timeIntervalSince1970: 1_767_225_600)))
        #expect(!Self.secretValues.contains { "\(secrets)".contains($0) || "\(report)".contains($0) })

        #expect(report.gistSync == GistSyncState(login: "octo-example", tauriGistID: "0123456789abcdef0123456789abcdef"))
        #expect(report.gistSync?.gistID == nil, "the Tauri app's gist is never this app's push target")
    }

    @Test func secretsAreAbsentFromEveryWrittenFile() async throws {
        let (workspace, preferences, report, secrets) = try imported()
        let store = InMemorySecretStore()
        for (item, value) in secrets.values { try store.set(value, for: item, profile: "default") }
        #expect(try store.string(for: .githubToken, profile: "default") == "FIXTURE-GITHUB-TOKEN-0005")

        let locations = DataLocations(root: FileManager.default.temporaryDirectory
            .appending(path: "alethe-import-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let profile = ProfileID(rawValue: "default")
        try FileManager.default.createDirectory(at: locations.profileDirectory(profile), withIntermediateDirectories: true)
        let workspaceStore = DocumentStore<WorkspaceDocument>(url: locations.workspace(profile))
        let preferencesStore = DocumentStore<PreferencesDocument>(url: locations.preferences(profile))
        try await workspaceStore.save(workspace, revision: 1)
        try await preferencesStore.save(preferences, revision: 1)
        try #require(report.gistSync).write(to: locations.gistSync(profile))

        let files = try FileManager.default.contentsOfDirectory(at: locations.profileDirectory(profile),
                                                                includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for secret in Self.secretValues {
                #expect(!text.contains(secret), "\(file.lastPathComponent) holds a secret")
            }
            #expect(!text.contains("remoteEnabled"))
        }
    }

    @Test func nothingSecretWithoutPreferences() throws {
        var context = Self.context
        context.includePreferences = false
        let (_, prefs, report, secrets) = try imported(context: context)
        #expect(report.secrets.isEmpty && report.gistSync == nil && secrets.values.isEmpty)
        #expect(prefs.router9 == nil && prefs.remote == nil && prefs.spotifyClientID == nil)
    }

    @Test func companionsTolerateMissingAndEmptyFiles() {
        let empty = TauriImport.Companions(spotifyTokens: nil, githubSync: Data(#"{"token":"  "}"#.utf8))
        #expect(empty.spotifyTokens == nil && empty.githubToken == nil && empty.gistSync == nil)
        let garbage = TauriImport.Companions(spotifyTokens: Data("not json".utf8), githubSync: Data("[]".utf8))
        #expect(garbage.spotifyTokens == nil && garbage.githubToken == nil)
        let missing = TauriImport.Companions.beside(URL(filePath: "/nonexistent-\(UUID().uuidString)/projects.json"))
        #expect(missing.spotifyTokens == nil && missing.gistSync == nil)
    }
}
