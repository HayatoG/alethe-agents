#if DEBUG
import AletheModel
import Foundation
import Synchronization

/// `-AletheUITestSeed` cases for GitHub gist sync; each hook ignores names it does not own.
///
/// `gistSync`: a project to sync, and a stub GitHub in this process (`GistSyncStub`) in place of the
/// real API — the token `ghp_uitest` is valid, any other is refused (401); pushed gists are kept in
/// memory and can be pulled back.
extension TestSeeds {
    /// Into the (empty) workspace being seeded.
    static func seedGistSync(_ name: String, into doc: inout WorkspaceDocument) {
        guard name == "gistSync" else { return }
        doc.addProject(name: "synced", folder: "/private/tmp", color: .blue)
    }

    /// Into the preferences, with the workspace seed.
    static func seedGistSync(_ name: String, into preferences: inout PreferencesDocument) {}

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedGistSync(_ name: String, environment: AppEnvironment) {
        guard name == "gistSync" else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GistSyncStub.self]
        environment.gistSync.useEndpoint(session: URLSession(configuration: configuration), apiBase: GistSyncStub.apiBase)
    }
}

/// A minimal GitHub gist API for UI tests: `GET /user`, `POST /gists`, `PATCH` and `GET /gists/{id}`.
final class GistSyncStub: URLProtocol {
    static let apiBase = URL(string: "https://github-stub.invalid")!
    static let validToken = "ghp_uitest"
    /// Gist id → file name → content.
    private static let gists = Mutex<[String: [String: String]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == apiBase.host() }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = respond()
        let response = HTTPURLResponse(url: request.url ?? Self.apiBase, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond() -> (Int, Any) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.validToken)" else {
            return (401, ["message": "Bad credentials"])
        }
        let parts = (request.url?.path() ?? "").split(separator: "/").map(String.init)
        switch (request.httpMethod ?? "GET", parts.count) {
        case ("GET", 1) where parts[0] == "user":
            return (200, ["login": "octo-uitest"])
        case ("POST", 1) where parts[0] == "gists":
            let id = "stub\(UUID().uuidString.prefix(8).lowercased())"
            Self.gists.withLock { $0[id] = files() }
            return (201, ["id": id])
        case ("PATCH", 2) where parts[0] == "gists":
            let found = Self.gists.withLock { gists -> Bool in
                guard gists[parts[1]] != nil else { return false }
                gists[parts[1]]?.merge(files()) { $1 }
                return true
            }
            return found ? (200, ["id": parts[1]]) : (404, ["message": "Not Found"])
        case ("GET", 2) where parts[0] == "gists":
            guard let files = Self.gists.withLock({ $0[parts[1]] }) else { return (404, ["message": "Not Found"]) }
            return (200, ["id": parts[1], "files": files.mapValues { ["content": $0, "truncated": false] }])
        default:
            return (404, ["message": "Not Found"])
        }
    }

    /// The `files` of a create or update body (URLSession hands bodies over as a stream).
    private func files() -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let files = object?["files"] as? [String: Any] ?? [:]
        return files.compactMapValues { ($0 as? [String: Any])?["content"] as? String }
    }
}
#endif
