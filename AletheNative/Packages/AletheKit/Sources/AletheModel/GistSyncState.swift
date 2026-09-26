import Foundation

/// GitHub gist sync status of a profile, `<profile>/github_sync.json` (upstream `SyncConfig` without
/// its token: the token is the `githubToken` Keychain item and never appears here).
public struct GistSyncState: Codable, Hashable, Sendable {
    public static let fileName = "github_sync.json"

    /// The GitHub account the token belongs to.
    public var login: String?
    /// This app's own gist.
    public var gistID: String?
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    /// The Tauri app's gist, from its imported `github_sync.json`. Kept apart from `gistID` so a push
    /// never overwrites the Tauri app's gist; it can still be pulled from.
    public var tauriGistID: String?

    public init(login: String? = nil, gistID: String? = nil, lastPushAt: Date? = nil, lastPullAt: Date? = nil,
                tauriGistID: String? = nil) {
        self.login = login
        self.gistID = gistID
        self.lastPushAt = lastPushAt
        self.lastPullAt = lastPullAt
        self.tauriGistID = tauriGistID
    }

    public var gistURL: URL? { gistID.flatMap { URL(string: "https://gist.github.com/\($0)") } }

    // MARK: - File

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The state in `url`; an empty state when the file is missing or unreadable.
    public static func load(from url: URL) -> GistSyncState {
        guard let data = try? Data(contentsOf: url) else { return GistSyncState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(GistSyncState.self, from: data)) ?? GistSyncState()
    }

    /// Atomic write (tmp → rename). Blocking: callers run it off the main thread.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }
}

extension DataLocations {
    public func gistSync(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: GistSyncState.fileName) }
}
