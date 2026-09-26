import Foundation

/// What a gist sync can fail with (upstream `github_sync.rs` error strings).
public enum GistSyncError: Error, Equatable, Sendable {
    /// `empty_token`.
    case emptyToken
    /// `invalid_token`: GitHub answered 401.
    case invalidToken
    /// `not_connected`: no token in the Keychain.
    case notConnected
    /// `nothing_to_sync`: the profile has none of the synced files.
    case nothingToSync
    /// `no_remote`: no gist id, or the gist is gone.
    case noRemote
    /// `remote_missing_projects`: the gist holds neither `workspace.json` nor upstream's `projects.json`.
    case remoteMissingWorkspace
    /// The gist or one of its files is not what the app wrote; nothing was changed.
    case malformedGist
    /// A pulled file does not decode (its name); nothing was changed.
    case invalidRemoteFile(String)
    /// A pulled file was written by a newer Alethe; nothing was changed.
    case newerFormat
    /// `github returned <status>`.
    case http(Int)
    /// The request did not complete (`URLError` code).
    case transport(Int)
}

/// The GitHub REST calls gist sync makes (upstream `auth`, `create_gist`, `gist_file_content`). The
/// token only ever goes to `apiBase` and GitHub's own hosts, and is never logged.
struct GistClient: Sendable {
    static let userAgent = "Alethe"
    static let apiVersion = "2022-11-28"

    let session: URLSession
    let apiBase: URL
    let token: String

    /// A file of a fetched gist: inline content, or a `raw_url` when GitHub truncated it (> 1 MB).
    struct RemoteFile: Sendable {
        var content: String?
        var truncated: Bool
        var rawURL: URL?
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw GistSyncError.transport(error.code.rawValue)
        }
    }

    private func endpoint(_ path: String) -> URL { apiBase.appending(path: path) }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GistSyncError.malformedGist
        }
        return object
    }

    private static func check(_ status: Int) throws {
        if status == 401 { throw GistSyncError.invalidToken }
        guard (200..<300).contains(status) else { throw GistSyncError.http(status) }
    }

    /// `GET /user`: the token's login (nil when GitHub leaves it out).
    func login() async throws -> String? {
        let (data, status) = try await send(request(endpoint("user")))
        try Self.check(status)
        return try Self.object(data)["login"] as? String
    }

    static func payload(files: [String: String], description: String) throws -> Data {
        let body: [String: Any] = [
            "description": description,
            "public": false,
            "files": files.mapValues { ["content": $0] },
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `POST /gists`: the new gist's id.
    func create(_ payload: Data) async throws -> String {
        let (data, status) = try await send(request(endpoint("gists"), method: "POST", body: payload))
        try Self.check(status)
        guard let id = try Self.object(data)["id"] as? String, !id.isEmpty else { throw GistSyncError.malformedGist }
        return id
    }

    /// `PATCH /gists/{id}`, creating a new gist when that one is gone (404) or refuses the edit (422).
    /// Returns the id written to.
    func update(_ id: String, with payload: Data) async throws -> String {
        let (_, status) = try await send(request(endpoint("gists/\(id)"), method: "PATCH", body: payload))
        if status == 404 || status == 422 { return try await create(payload) }
        try Self.check(status)
        return id
    }

    /// `GET /gists/{id}`: its files by name.
    func files(of id: String) async throws -> [String: RemoteFile] {
        let (data, status) = try await send(request(endpoint("gists/\(id)")))
        if status == 404 { throw GistSyncError.noRemote }
        try Self.check(status)
        guard let files = try Self.object(data)["files"] as? [String: Any] else { throw GistSyncError.malformedGist }
        var result: [String: RemoteFile] = [:]
        for (name, value) in files {
            guard let file = value as? [String: Any] else { continue }
            result[name] = RemoteFile(content: file["content"] as? String, truncated: file["truncated"] as? Bool ?? false,
                                      rawURL: (file["raw_url"] as? String).flatMap(URL.init(string:)))
        }
        return result
    }

    /// A file's full text (upstream `gist_file_content`): inline, or read from `raw_url` when truncated.
    func content(of file: RemoteFile) async throws -> String? {
        guard file.truncated else { return file.content }
        guard let raw = file.rawURL else { return nil }
        guard isTrusted(raw) else { throw GistSyncError.malformedGist }
        let (data, status) = try await send(request(raw))
        try Self.check(status)
        return String(decoding: data, as: UTF8.self)
    }

    /// Hosts the token may be sent to: the API host itself and GitHub's gist content hosts over HTTPS.
    func isTrusted(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host == apiBase.host()?.lowercased(), url.scheme == apiBase.scheme { return true }
        guard url.scheme == "https" else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host == "githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }
}
