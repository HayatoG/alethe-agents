import Foundation

// The types the remote tasks share: the transport (P7-7) turns sockets into `RemoteRequest`s and
// hands them to a `RemoteRouter` (the API, P7-8), which reads the app through the three sources
// (P7-9 assets, P7-12 terminals and workspace). None of them decides policy on its own.

// MARK: - HTTP

/// One parsed HTTP request, as the transport read it within `RemoteLimits`.
public struct RemoteRequest: Sendable, Equatable {
    public var method: String
    /// The request target: path plus query (`/api/scrollback?id=…`).
    public var target: String
    /// Header values by lowercased name (the first occurrence wins).
    public var headers: [String: String]
    public var body: Data
    /// The peer as `ip:port` — used for per-address lockouts and shown on the device list.
    public var peerAddress: String

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data(), peerAddress: String) {
        self.method = method
        self.target = target
        var lowered: [String: String] = [:]
        for (name, value) in headers where lowered[name.lowercased()] == nil {
            lowered[name.lowercased()] = value
        }
        self.headers = lowered
        self.body = body
        self.peerAddress = peerAddress
    }

    public var path: String {
        target.firstIndex(of: "?").map { String(target[..<$0]) } ?? target
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func queryValue(_ key: String) -> String? {
        RemoteText.queryValue(target, key)
    }

    /// The `Authorization: Bearer …` session token, or `""`.
    public var bearerToken: String {
        guard let value = header("authorization") else { return "" }
        for prefix in ["Bearer ", "bearer "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return ""
    }
}

/// One HTTP response. The transport writes `head()` and `body`, refusing bodies over `sizeLimit`.
public struct RemoteResponse: Sendable, Equatable {
    public enum Caching: Sendable, Equatable {
        case noStore, immutable

        public var headerValue: String {
            switch self {
            case .noStore: "no-store"
            case .immutable: "public, max-age=31536000, immutable"
            }
        }
    }

    public enum SizeLimit: Sendable, Equatable {
        /// 64 KB: API answers and errors.
        case standard
        /// 4 MB: scrollback, transcripts and static assets.
        case large

        public var bytes: Int {
            switch self {
            case .standard: RemoteLimits.maxBody
            case .large: RemoteLimits.maxStaticAsset
            }
        }
    }

    public var status: Int
    public var contentType: String
    public var body: Data
    public var caching: Caching
    public var sizeLimit: SizeLimit

    public init(status: Int, contentType: String, body: Data, caching: Caching = .noStore, sizeLimit: SizeLimit = .standard) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.caching = caching
        self.sizeLimit = sizeLimit
    }

    public static func json(_ status: Int, _ body: Data, sizeLimit: SizeLimit = .standard) -> RemoteResponse {
        RemoteResponse(status: status, contentType: "application/json", body: body, sizeLimit: sizeLimit)
    }

    public static func json<Value: Encodable>(_ status: Int, encoding value: Value, sizeLimit: SizeLimit = .standard) -> RemoteResponse {
        guard let data = try? RemoteFrame.encoder.encode(value) else {
            return error(500, "Internal error")
        }
        return json(status, data, sizeLimit: sizeLimit)
    }

    /// `{"error": message}` — the client shows `message` as is.
    public static func error(_ status: Int, _ message: String) -> RemoteResponse {
        json(status, encoding: ["error": message])
    }

    public static let noContent = RemoteResponse(status: 204, contentType: "text/plain", body: Data())
    public static let notFound = RemoteResponse(status: 404, contentType: "text/plain", body: Data("Not found".utf8))

    public var exceedsLimit: Bool { body.count > sizeLimit.bytes }

    public var reasonPhrase: String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }

    /// The status line and headers (upstream `respond_bytes_with_limit`), ending with the blank line.
    public func head() -> String {
        "HTTP/1.1 \(status) \(reasonPhrase)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: \(caching.headerValue)\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: \(Self.contentSecurityPolicy)\r\n\r\n"
    }

    public static let contentSecurityPolicy = "default-src 'self'; connect-src 'self' ws:; img-src 'self' data:; "
        + "style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'"
}

/// Answers every HTTP request the transport accepted (the API, P7-8).
public protocol RemoteRouter: Sendable {
    func route(_ request: RemoteRequest) async -> RemoteResponse
}

// MARK: - Sources

public struct RemoteTerminalSize: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// Upstream's size for a terminal that reports none.
    public static let fallback = RemoteTerminalSize(cols: 80, rows: 24)
}

public enum RemoteInputError: Error, Equatable, Sendable {
    case notFound
    /// The tab has no live process (the API answers 409).
    case notRunning
    case failed(String)
}

/// Live output of a terminal, for the hub to publish to subscribed devices.
public enum RemoteTerminalOutput: Equatable, Sendable {
    case data(terminalID: String, text: String)
    case exit(terminalID: String, reason: String)

    public var terminalID: String {
        switch self {
        case .data(let id, _), .exit(let id, _): id
        }
    }

    /// The WebSocket frame upstream sends for it (`pty_output` / `pty_exit`).
    public var frame: String {
        switch self {
        case .data(let id, let text): RemoteFrame.encode(["type": "pty_output", "ptyId": id, "text": text])
        case .exit(let id, let reason): RemoteFrame.encode(["type": "pty_exit", "ptyId": id, "reason": reason])
        }
    }
}

/// The app's terminals, by tab id (`ptyId` on the wire).
public protocol RemoteTerminalSource: Sendable {
    /// The last `maxBytes` of the tab's scrollback, cut on a character boundary.
    func scrollbackTail(terminalID: String, maxBytes: Int) async -> String
    func size(terminalID: String) async -> RemoteTerminalSize?
    /// Writes `text` to the tab's PTY as typed input.
    func write(terminalID: String, text: String) async throws(RemoteInputError)
    /// Output of every running tab; forwarded into `RemoteHub.publish`, which drops it unless a
    /// device subscribed to that tab.
    func output() -> AsyncStream<RemoteTerminalOutput>
}

/// A tab the user shared with remote devices (`Pane.remoteShared`).
public struct RemoteSharedTab: Codable, Equatable, Sendable {
    public var terminalID: String
    /// Upstream agent id: `claude`, `codex`, `opencode` or `shell`.
    public var agent: String
    public var cwd: String
    public var sessionID: String?

    public init(terminalID: String, agent: String, cwd: String, sessionID: String?) {
        self.terminalID = terminalID
        self.agent = agent
        self.cwd = cwd
        self.sessionID = sessionID
    }

    /// Claude Code and Codex expose transcripts, questions and interrupts remotely.
    public var isControllableAgent: Bool { agent == "claude" || agent == "codex" }
    public var isShell: Bool { agent == "shell" }
}

/// `/api/state` (upstream `workspace_snapshot`): groups, and projects with their shared chats only.
public struct RemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var color: String?

        public init(id: String, name: String, color: String?) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    public struct Chat: Codable, Equatable, Sendable {
        public var id: String
        public var ptyId: String
        public var name: String
        public var agent: String
        public var terminalId: String

        public init(id: String, ptyId: String, name: String, agent: String, terminalId: String) {
            self.id = id
            self.ptyId = ptyId
            self.name = name
            self.agent = agent
            self.terminalId = terminalId
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var groupId: String?
        public var color: String?
        public var chats: [Chat]

        public init(id: String, name: String, groupId: String?, color: String?, chats: [Chat]) {
            self.id = id
            self.name = name
            self.groupId = groupId
            self.color = color
            self.chats = chats
        }
    }

    public var groups: [Group]
    public var projects: [Project]

    public init(groups: [Group], projects: [Project]) {
        self.groups = groups
        self.projects = projects
    }
}

/// `/appearance.json` (upstream `RemoteAppearance`): the phone mirrors the Mac's look.
public struct RemoteAppearance: Codable, Equatable, Sendable {
    public var uiTheme: String
    public var appIconTheme: String
    public var language: String
    public var motionPreference: String
    public var colorScheme: String

    public init(uiTheme: String, appIconTheme: String, language: String, motionPreference: String, colorScheme: String) {
        self.uiTheme = uiTheme
        self.appIconTheme = appIconTheme
        self.language = language
        self.motionPreference = motionPreference
        self.colorScheme = colorScheme
    }
}

public struct RemoteQuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// An interactive agent question (Claude Code `AskUserQuestion`, Codex `request_user_input`).
public struct RemoteQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var header: String
    public var question: String
    public var multiSelect: Bool
    public var options: [RemoteQuestionOption]

    public init(id: String, header: String, question: String, multiSelect: Bool, options: [RemoteQuestionOption]) {
        self.id = id
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// The questions still awaiting an answer; `id` is the agent's tool call id.
public struct RemoteQuestionSet: Codable, Equatable, Sendable {
    public var id: String
    public var questions: [RemoteQuestion]

    public init(id: String, questions: [RemoteQuestion]) {
        self.id = id
        self.questions = questions
    }
}

/// `/api/transcript` (upstream `TranscriptSnapshot`).
public struct RemoteTranscript: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        /// `user`, `assistant` or `tool`.
        public var role: String
        public var text: String
        public var questionSetId: String?
        public var questions: [RemoteQuestion]?

        public init(role: String, text: String, questionSetId: String? = nil, questions: [RemoteQuestion]? = nil) {
            self.role = role
            self.text = text
            self.questionSetId = questionSetId
            self.questions = questions
        }
    }

    public var sessionId: String?
    /// The transcript file's modification time in ms; an unchanged revision skips the parse.
    public var revision: UInt64
    public var unchanged: Bool
    public var messages: [Message]

    public init(sessionId: String?, revision: UInt64, unchanged: Bool, messages: [Message]) {
        self.sessionId = sessionId
        self.revision = revision
        self.unchanged = unchanged
        self.messages = messages
    }
}

/// The app's workspace as remote devices see it.
public protocol RemoteWorkspaceSource: Sendable {
    /// Every tab of every shared pane.
    func sharedTabs() async -> [RemoteSharedTab]
    func snapshot() async -> RemoteWorkspaceSnapshot
    func appearance() async -> RemoteAppearance
    /// The tab's agent transcript (Claude Code and Codex); `since` is the client's last revision.
    func transcript(for tab: RemoteSharedTab, since: UInt64?, limit: Int) async throws -> RemoteTranscript
    /// The questions the tab's agent is waiting on, if any.
    func activeQuestions(for tab: RemoteSharedTab) async -> RemoteQuestionSet?
}

public extension RemoteWorkspaceSource {
    func sharedTab(_ terminalID: String) async -> RemoteSharedTab? {
        await sharedTabs().first { $0.terminalID == terminalID }
    }
}

/// A file of the bundled phone client.
public struct RemoteAsset: Sendable, Equatable {
    public var data: Data
    public var contentType: String
    public var caching: RemoteResponse.Caching

    public init(data: Data, contentType: String, caching: RemoteResponse.Caching) {
        self.data = data
        self.contentType = contentType
        self.caching = caching
    }

    public var response: RemoteResponse {
        RemoteResponse(status: 200, contentType: contentType, body: data, caching: caching, sizeLimit: .large)
    }
}

/// The phone client's static files (P7-9); `appIconTheme` picks `/brand-icon.png`.
public protocol RemoteAssetSource: Sendable {
    func asset(at path: String, appIconTheme: String) async -> RemoteAsset?
}

// MARK: - Events

/// A device's input reached a terminal (upstream `remote://message`).
public struct RemoteMessageEvent: Codable, Equatable, Sendable {
    public var terminalID: String
    public var deviceID: Int
    public var deviceName: String
    /// At most 120 characters.
    public var preview: String

    public init(terminalID: String, deviceID: Int, deviceName: String, preview: String) {
        self.terminalID = terminalID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.preview = RemoteText.truncated(preview, to: RemoteLimits.maxPreview)
    }
}

/// What remote control tells the app.
public enum RemoteEvent: Equatable, Sendable {
    case message(RemoteMessageEvent)
    /// A listener could not bind; remote control turned itself off.
    case startFailed
    /// No device was paired for `RemoteLimits.idleDisable`; remote control turned itself off.
    case autoDisabled
}

// MARK: - WebSocket frames

/// JSON text frames the WebSocket sends besides terminal output.
public enum RemoteFrame {
    public static let authenticated = encode(["type": "authenticated"])
    public static let expired = encode(["type": "error", "reason": "expired", "message": "Remote session expired"])
    public static let unauthorized = encode(["type": "error", "reason": "unauthorized", "message": "Remote session is not valid"])

    public static func scrollback(terminalID: String, text: String, size: RemoteTerminalSize) -> String {
        struct Payload: Encodable {
            let type = "scrollback"
            let ptyId: String
            let text: String
            let cols: Int
            let rows: Int
        }
        return encode(Payload(ptyId: terminalID, text: text, cols: size.cols, rows: size.rows))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func encode<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
