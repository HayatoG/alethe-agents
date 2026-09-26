import AletheFoundation
import AletheModel
import Foundation

/// What the GitHub Sync sheet shows (upstream `GithubSyncStatus`); never the token.
public struct GistSyncStatus: Hashable, Sendable {
    public var connected: Bool
    public var login: String?
    public var gistID: String?
    public var gistURL: URL?
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    /// The imported Tauri app's gist: pulled from when this app has none of its own, never pushed to.
    public var tauriGistID: String?

    init(connected: Bool, state: GistSyncState) {
        self.connected = connected
        login = state.login
        gistID = state.gistID
        gistURL = state.gistURL
        lastPushAt = state.lastPushAt
        lastPullAt = state.lastPullAt
        tauriGistID = state.tauriGistID
    }
}

/// A validated pull that replaces this profile's workspace (and the preferences and activity it
/// carried). Nothing has changed yet: the user confirms, then the app takes a safety backup,
/// schedules `operation` and relaunches (the P5-10 path); otherwise `GistSyncService.discard`.
public struct StagedGistPull: Hashable, Sendable {
    /// The whole data folder to discard (inside `DataLocations.importStaging`).
    public var stagingRoot: URL
    /// The profile folder as it will be after the relaunch.
    public var profileFolder: URL
    public var operation: PendingDataOperation
    /// Synced file names taken from the gist.
    public var files: [String]
    public var projects: Int
    public var terminals: Int
}

/// A gist holding only upstream's `projects.json`: offered as a Tauri import instead (P1-12 mapping).
public struct TauriGistPull: Hashable, Sendable {
    public var stagingRoot: URL
    /// The pulled `projects.json`, already checked to parse as a supported Tauri file.
    public var projectsFile: URL
}

public enum GistPullResult: Hashable, Sendable {
    /// Replaces this profile's data: the UI must ask before applying it.
    case replacesProfile(StagedGistPull)
    case tauriImport(TauriGistPull)

    public var stagingRoot: URL {
        switch self {
        case .replacesProfile(let pull): pull.stagingRoot
        case .tauriImport(let pull): pull.stagingRoot
        }
    }
}

/// GitHub gist sync of one profile (P7-11, upstream `github_sync.rs`). The token is the profile's
/// `githubToken` Keychain item; everything else is its `github_sync.json`. Pushes go to this app's own
/// private gist only, never to the Tauri app's. Every call runs off the main thread and stops when its
/// task is cancelled.
public actor GistSyncService {
    public static let gistDescription = "Alethe for Mac sync — workspace, preferences & activity (managed by the app)"
    public static let defaultAPIBase = URL(string: "https://api.github.com")!
    static let workspaceFile = "workspace.json"
    static let preferencesFile = "preferences.json"
    static let activityFile = "activity-stats.json"
    static let tauriProjectsFile = "projects.json"
    public static let syncedFiles = [workspaceFile, preferencesFile, activityFile]

    public let profile: ProfileID
    private let locations: DataLocations
    private let secrets: any SecretStore
    private let session: URLSession
    private let apiBase: URL
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    public init(profile: ProfileID, locations: DataLocations, secrets: any SecretStore,
                session: URLSession = GistSyncService.makeSession(), apiBase: URL = GistSyncService.defaultAPIBase,
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { AppLog.info(.integrations, $0) }) {
        self.profile = profile
        self.locations = locations
        self.secrets = secrets
        self.session = session
        self.apiBase = apiBase
        self.now = now
        self.log = log
    }

    /// Ephemeral (no cookies or cache on disk) with request and resource timeouts.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    // MARK: - Status and token

    private var stateURL: URL { locations.gistSync(profile) }
    private var profileFolder: URL { locations.profileDirectory(profile) }

    private func token() throws -> String? {
        let token = try secrets.string(for: .githubToken, profile: profile.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func client() throws -> GistClient {
        guard let token = try token() else { throw GistSyncError.notConnected }
        return GistClient(session: session, apiBase: apiBase, token: token)
    }

    public func status() throws -> GistSyncStatus {
        GistSyncStatus(connected: try token() != nil, state: GistSyncState.load(from: stateURL))
    }

    /// Checks `token` with `GET /user`, then keeps it in the Keychain and its login in the state.
    public func connect(token raw: String) async throws -> GistSyncStatus {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GistSyncError.emptyToken }
        let login = try await GistClient(session: session, apiBase: apiBase, token: token).login()
        try Task.checkCancellation()
        try secrets.setString(token, for: .githubToken, profile: profile.rawValue)
        var state = GistSyncState.load(from: stateURL)
        state.login = login
        try state.write(to: stateURL)
        log("gist sync connected (profile \(profile.rawValue))")
        return GistSyncStatus(connected: true, state: state)
    }

    /// Deletes the token and forgets the login; the gist ids stay for a later reconnect.
    public func disconnect() throws -> GistSyncStatus {
        try secrets.delete(.githubToken, profile: profile.rawValue)
        var state = GistSyncState.load(from: stateURL)
        state.login = nil
        try state.write(to: stateURL)
        log("gist sync disconnected (profile \(profile.rawValue))")
        return GistSyncStatus(connected: false, state: state)
    }

    // MARK: - Push

    /// The profile's synced files that exist and are not blank (upstream `collect_files`).
    func collectFiles() throws -> [String: String] {
        var files: [String: String] = [:]
        for name in Self.syncedFiles {
            let url = profileFolder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { files[name] = content }
        }
        return files
    }

    /// Uploads the synced files to this app's gist: `PATCH` when its id is known (a new gist if that one
    /// is gone), a new private gist otherwise. The caller saves open documents first.
    public func push() async throws -> GistSyncStatus {
        let client = try client()
        let files = try collectFiles()
        guard !files.isEmpty else { throw GistSyncError.nothingToSync }
        let payload = try GistClient.payload(files: files, description: Self.gistDescription)
        let state = GistSyncState.load(from: stateURL)
        // Never the Tauri app's gist, even if an id was copied over by hand.
        let target = state.gistID.flatMap { $0 == state.tauriGistID ? nil : $0 }
        let id: String
        if let target {
            id = try await client.update(target, with: payload)
        } else {
            id = try await client.create(payload)
        }
        try Task.checkCancellation()
        var updated = GistSyncState.load(from: stateURL)
        updated.gistID = id
        updated.lastPushAt = now()
        try updated.write(to: stateURL)
        log("gist push: \(files.count) files, \(payload.count) bytes")
        return GistSyncStatus(connected: true, state: updated)
    }

    // MARK: - Pull

    /// Downloads the gist (this app's, else the imported Tauri app's) and stages it without changing
    /// anything: a native gist is validated by decoding and staged as the next launch's profile folder;
    /// a Tauri gist is offered as a Tauri import.
    public func pull() async throws -> GistPullResult {
        let client = try client()
        let state = GistSyncState.load(from: stateURL)
        guard let id = state.gistID ?? state.tauriGistID else { throw GistSyncError.noRemote }
        let remote = try await client.files(of: id)

        var contents: [String: String] = [:]
        let wanted = remote[Self.workspaceFile] != nil ? Self.syncedFiles : [Self.tauriProjectsFile]
        for name in wanted {
            guard let file = remote[name] else { continue }
            if let text = try await client.content(of: file) { contents[name] = text }
        }
        try Task.checkCancellation()

        let stagingRoot = locations.importStaging.appending(path: "gist-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            let result: GistPullResult
            if contents[Self.workspaceFile] != nil {
                result = .replacesProfile(try await stageProfile(contents, into: stagingRoot))
            } else if let projects = contents[Self.tauriProjectsFile] {
                result = .tauriImport(try stageTauri(projects, into: stagingRoot))
            } else {
                throw GistSyncError.remoteMissingWorkspace
            }
            log("gist pull staged: \(contents.count) files, \(contents.values.reduce(0) { $0 + $1.utf8.count }) bytes")
            return result
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Validates the pulled files in a scratch folder, then lays them over a copy of the profile folder
    /// (scrollback, history and sync state carried over) with the pull time recorded in its sync state.
    private func stageProfile(_ contents: [String: String], into stagingRoot: URL) async throws -> StagedGistPull {
        let manager = FileManager.default
        let check = stagingRoot.appending(path: "check", directoryHint: .isDirectory)
        try manager.createDirectory(at: check, withIntermediateDirectories: true)
        for (name, text) in contents { try Data(text.utf8).write(to: check.appending(path: name)) }
        try await Self.validate(WorkspaceDocument.self, check.appending(path: Self.workspaceFile))
        if contents[Self.preferencesFile] != nil {
            try await Self.validate(PreferencesDocument.self, check.appending(path: Self.preferencesFile))
        }
        if contents[Self.activityFile] != nil {
            guard (try? ActivityStats.load(from: check.appending(path: Self.activityFile))) != nil else {
                throw GistSyncError.invalidRemoteFile(Self.activityFile)
            }
        }
        try Task.checkCancellation()

        let folder = stagingRoot.appending(path: "profile", directoryHint: .isDirectory)
        try ProfileFiles.copyProfileFolder(from: profileFolder, to: folder)
        for (name, text) in contents { try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic) }
        var state = GistSyncState.load(from: folder.appending(path: GistSyncState.fileName))
        state.lastPullAt = now()
        try state.write(to: folder.appending(path: GistSyncState.fileName))
        try? manager.removeItem(at: check)

        let counts = ProfileFiles.counts(ofWorkspaceAt: folder.appending(path: Self.workspaceFile))
        return StagedGistPull(stagingRoot: stagingRoot, profileFolder: folder,
                              operation: .importProfile(profile, stagedFolder: folder.path),
                              files: contents.keys.sorted(), projects: counts.projects, terminals: counts.terminals)
    }

    /// Decodes a pulled document the way launch loads it (migrations included); unreadable → refused.
    private static func validate<Document: VersionedDocument>(_: Document.Type, _ url: URL) async throws {
        do {
            let (_, outcome) = try await DocumentStore<Document>(url: url).load()
            if case .recoveredFromCorruption = outcome { throw GistSyncError.invalidRemoteFile(url.lastPathComponent) }
        } catch let error as DocumentStoreError {
            if case .newerVersion = error { throw GistSyncError.newerFormat }
            throw GistSyncError.invalidRemoteFile(url.lastPathComponent)
        }
    }

    private func stageTauri(_ projects: String, into stagingRoot: URL) throws -> TauriGistPull {
        do {
            _ = try TauriImport.File(data: Data(projects.utf8))
        } catch {
            throw GistSyncError.invalidRemoteFile(Self.tauriProjectsFile)
        }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let file = stagingRoot.appending(path: Self.tauriProjectsFile)
        try Data(projects.utf8).write(to: file, options: .atomic)
        return TauriGistPull(stagingRoot: stagingRoot, projectsFile: file)
    }

    /// Drops a pull the user did not apply.
    public nonisolated func discard(_ pull: GistPullResult) {
        try? FileManager.default.removeItem(at: pull.stagingRoot)
    }
}
