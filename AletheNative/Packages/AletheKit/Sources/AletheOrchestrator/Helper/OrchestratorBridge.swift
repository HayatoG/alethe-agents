import Foundation
import AletheIntegrations

/// What a Codex planner's stdio helper needs to reach the app: the loopback endpoint, its token and
/// the planner id. Written per launch by the app into a private (0600) file whose path is the only
/// thing in the helper's arguments, so the token never shows in a process listing.
public struct OrchestratorBridgeFile: Codable, Equatable, Sendable, CustomStringConvertible {
    public var endpoint: String
    public var token: String
    public var planner: String

    public init(endpoint: String, token: String, planner: String) {
        self.endpoint = endpoint
        self.token = token
        self.planner = planner
    }

    public enum ReadError: Error, Equatable, Sendable {
        case unreadable
        /// Readable by others than its owner: a leaked token is not used.
        case notPrivate
        case malformed
    }

    /// The app's `POST /mcp`.
    public var mcpURL: URL? {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/mcp"), url.scheme == "http" else { return nil }
        return url
    }

    /// Never prints the token.
    public var description: String { "OrchestratorBridgeFile(endpoint: \(endpoint), planner: \(planner))" }

    public static func read(from url: URL) throws(ReadError) -> OrchestratorBridgeFile {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url)
        else { throw .unreadable }
        if let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 != 0 {
            throw .notPrivate
        }
        guard let file = try? JSONDecoder().decode(OrchestratorBridgeFile.self, from: data),
              !file.token.isEmpty, !file.planner.isEmpty, file.mcpURL != nil
        else { throw .malformed }
        return file
    }

    /// Atomic (tmp → rename) 0600 write; the folder is created 0700 when missing.
    public func write(to url: URL) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Bridge mode of `alethe-orchestrator-mcp` (replaces upstream's generated PowerShell bridge,
/// `write_codex_mcp_bridge`): each stdin line is posted to the app's `/mcp` as the planner and the
/// answer written back as one line. A notification is forwarded and gets no line. Where upstream
/// swallowed a failed post, a request here gets a JSON-RPC error so the client never waits forever.
public struct OrchestratorBridge: Sendable {
    public typealias Post = @Sendable (_ body: Data) async throws -> (status: Int, body: Data)

    /// JSON-RPC internal error, for an app that cannot answer.
    public static let unavailableCode = -32603

    private let post: Post

    public init(post: @escaping Post) {
        self.post = post
    }

    /// Posts over loopback with the token and planner as headers.
    public init(file: OrchestratorBridgeFile, session: URLSession = OrchestratorBridge.session) {
        self.init { body in
            guard let request = Self.request(for: file, body: body) else { throw URLError(.badURL) }
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// No proxies, no caches or cookies; long enough for `alethe_check`'s longest wait.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = TimeInterval(OrchestratorLimits.maxWaitMs / 1000) * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public static func request(for file: OrchestratorBridgeFile, body: Data) -> URLRequest? {
        guard let url = file.mcpURL else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(file.token, forHTTPHeaderField: OrchestratorPlannerLaunch.tokenHeader)
        request.setValue(file.planner, forHTTPHeaderField: OrchestratorPlannerLaunch.plannerHeader)
        request.httpBody = body
        return request
    }

    /// One stdin line in, the line to write back out (nil: nothing to write — a blank line, a body
    /// that is not a JSON object, or a notification).
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = (try? OrderedJSON.parse(trimmed))?.objectValue else { return nil }
        let id = message["id"]
        let reply: (status: Int, body: Data)
        do {
            reply = try await post(Data(trimmed.utf8))
        } catch {
            return id.map { Self.error(id: $0, "Alethe is not reachable") }
        }
        guard let id else { return nil }
        switch reply.status {
        case 200:
            if let line = Self.singleLine(reply.body) { return line }
            return Self.error(id: id, "Alethe sent an empty answer")
        case 401: return Self.error(id: id, "Alethe refused this terminal's credentials; reopen the terminal")
        case 404: return Self.error(id: id, "Alethe's orchestrator is off")
        default: return Self.error(id: id, "Alethe answered HTTP \(reply.status)")
        }
    }

    /// The answer as exactly one line (the app's replies are compact already).
    static func singleLine(_ body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.contains(where: \.isNewline) else { return text }
        return (try? OrderedJSON.parse(text))?.compactRendered()
    }

    static func error(id: OrderedJSON, _ message: String) -> String {
        let response: OrderedJSON = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": .integer(unavailableCode), "message": .string(message)],
        ]
        return response.compactRendered()
    }
}
