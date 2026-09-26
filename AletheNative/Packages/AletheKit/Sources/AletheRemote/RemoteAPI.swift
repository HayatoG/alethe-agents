import Foundation

/// Remote control's HTTP surface (upstream `remote/http.rs` `handle_http`/`handle_api`): pairing,
/// the bearer-authorized `/api/*` routes and the phone client's static files. Policy lives here —
/// session checks, sharing, read-only, shell input, rate limits — so the transport only moves bytes.
/// Tokens and message text never reach the log; device ids and sizes do.
public struct RemoteAPI: RemoteRouter {
    public let hub: RemoteHub
    private let terminals: any RemoteTerminalSource
    private let workspace: any RemoteWorkspaceSource
    private let assets: any RemoteAssetSource

    /// Longest terminal id a request may name; real ids are short nanoids.
    static let maxTerminalID = 128
    /// Longest custom answer typed into an agent question (upstream `take(1_000)`).
    static let maxCustomAnswer = 1_000

    public init(
        hub: RemoteHub,
        terminals: any RemoteTerminalSource,
        workspace: any RemoteWorkspaceSource,
        assets: any RemoteAssetSource
    ) {
        self.hub = hub
        self.terminals = terminals
        self.workspace = workspace
        self.assets = assets
    }

    public func route(_ request: RemoteRequest) async -> RemoteResponse {
        let address = request.peerAddress
        if await hub.authBlocked(address) {
            return .error(429, "Too many failed attempts")
        }
        guard request.body.count <= RemoteLimits.maxBody else { return .badRequest }
        let path = request.path

        if path == "/api/pair", request.method == "POST" {
            return await pair(request)
        }
        if path == "/appearance.json", request.method == "GET" {
            return .json(200, encoding: await workspace.appearance().normalized)
        }
        if path.hasPrefix("/api/") {
            guard let sessionID = await hub.sessionID(for: request.bearerToken) else {
                await hub.recordAuthFailure(address)
                return .error(401, "Remote session is not valid")
            }
            await hub.clearAuthFailures(address)
            await hub.touchActivity()
            return await api(request, path: path, sessionID: sessionID)
        }
        return await staticAsset(path)
    }

    // MARK: Pairing

    private struct PairRequest: Decodable {
        var token: String
        var deviceName: String?
    }

    private func pair(_ request: RemoteRequest) async -> RemoteResponse {
        guard let payload = Self.decode(PairRequest.self, request.body) else { return .badRequest }
        let name = RemoteText.sanitize(payload.deviceName ?? "Remote device")
            .trimmingCharacters(in: .whitespaces)
        let deviceName = RemoteText.truncated(name.isEmpty ? "Remote device" : name, to: RemoteLimits.maxDeviceName)
        let pairing: RemotePairing
        do {
            pairing = try await hub.pair(token: payload.token, name: deviceName, address: request.peerAddress)
        } catch {
            await hub.recordAuthFailure(request.peerAddress)
            return .error(401, error.message)
        }
        await hub.clearAuthFailures(request.peerAddress)
        let info = await hub.info()
        return .json(200, encoding: SessionPayload(info: info, pairing: pairing))
    }

    /// `/api/pair` and `/api/info` answers; `wsUrl` is sent as `null` when unknown, as upstream.
    private struct SessionPayload: Encodable {
        var info: RemoteInfo
        var pairing: RemotePairing?

        enum CodingKeys: String, CodingKey {
            case sessionToken, deviceId, wsUrl, readOnly, allowShellInput, sessionExpirySecs
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let pairing {
                try container.encode(pairing.sessionToken, forKey: .sessionToken)
                try container.encode(pairing.deviceID, forKey: .deviceId)
            }
            try container.encode(info.wsURL, forKey: .wsUrl)
            try container.encode(info.readOnly, forKey: .readOnly)
            try container.encode(info.allowShellInput, forKey: .allowShellInput)
            try container.encode(info.sessionExpirySecs, forKey: .sessionExpirySecs)
        }
    }

    // MARK: API

    private func api(_ request: RemoteRequest, path: String, sessionID: Int) async -> RemoteResponse {
        switch (path, request.method) {
        case ("/api/info", _):
            return .json(200, encoding: SessionPayload(info: await hub.info(), pairing: nil))
        case ("/api/state", _):
            return .json(200, encoding: await workspace.snapshot(), sizeLimit: .large)
        case ("/api/scrollback", _):
            return await scrollback(request, sessionID: sessionID)
        case ("/api/transcript", _):
            return await transcript(request)
        case ("/api/question-answer", "POST"):
            if let refused = await inputGate(sessionID) { return refused }
            return await questionAnswer(request, sessionID: sessionID)
        case ("/api/agent-control", "POST"):
            if let refused = await inputGate(sessionID) { return refused }
            return await agentControl(request, sessionID: sessionID)
        case ("/api/message", "POST"):
            if let refused = await inputGate(sessionID) { return refused }
            return await message(request, sessionID: sessionID)
        default:
            return .error(404, "Not found")
        }
    }

    private func scrollback(_ request: RemoteRequest, sessionID: Int) async -> RemoteResponse {
        guard let id = Self.terminalID(request.queryValue("id")) else { return .badRequest }
        guard await workspace.sharedTab(id) != nil else { return .notShared }
        await hub.setSubscription(sessionID, terminalID: id)
        let text = await terminals.scrollbackTail(terminalID: id, maxBytes: RemoteLimits.maxScrollback)
        let size = await terminals.size(terminalID: id) ?? .fallback
        return .json(200, encoding: ScrollbackPayload(text: text, cols: size.cols, rows: size.rows), sizeLimit: .large)
    }

    private struct ScrollbackPayload: Encodable {
        var text: String
        var cols: Int
        var rows: Int
    }

    private func transcript(_ request: RemoteRequest) async -> RemoteResponse {
        guard let id = Self.terminalID(request.queryValue("id")) else { return .badRequest }
        guard let tab = await workspace.sharedTab(id) else { return .notShared }
        guard tab.isControllableAgent else {
            return .json(200, encoding: TranscriptPayload(snapshot: nil, agent: tab.agent, supported: false, error: nil))
        }
        let since = request.queryValue("since").flatMap { UInt64($0) }
        do {
            let snapshot = try await workspace.transcript(for: tab, since: since, limit: RemoteLimits.maxTranscriptEvents)
            return .json(200, encoding: TranscriptPayload(snapshot: snapshot, agent: tab.agent, supported: true, error: nil), sizeLimit: .large)
        } catch {
            // The underlying error may name local paths; the phone gets a fixed message.
            return .json(200, encoding: TranscriptPayload(snapshot: nil, agent: tab.agent, supported: true, error: "Transcript is not available"))
        }
    }

    /// The snapshot's fields plus `supported` and `agent` (upstream merges them into one object).
    private struct TranscriptPayload: Encodable {
        var snapshot: RemoteTranscript?
        var agent: String
        var supported: Bool
        var error: String?

        enum CodingKeys: String, CodingKey { case supported, agent, error }

        func encode(to encoder: Encoder) throws {
            try snapshot?.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(supported, forKey: .supported)
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }

    /// Read-only and the per-session rate, checked before any input is parsed.
    private func inputGate(_ sessionID: Int) async -> RemoteResponse? {
        if await hub.isReadOnly {
            return .error(403, "Remote control is in read-only mode")
        }
        guard await hub.allowMessage(sessionID) else {
            return .error(429, "Too many messages, slow down")
        }
        return nil
    }

    private struct QuestionAnswerRequest: Decodable {
        var ptyId: String
        var questionSetId: String
        var selections: [[Int]]
        var customAnswers: [String?]?
    }

    private func questionAnswer(_ request: RemoteRequest, sessionID: Int) async -> RemoteResponse {
        guard let payload = Self.decode(QuestionAnswerRequest.self, request.body),
              let id = Self.terminalID(payload.ptyId) else { return .badRequest }
        guard let tab = await workspace.sharedTab(id) else { return .notShared }
        guard tab.isControllableAgent else {
            return .error(409, "This agent does not expose interactive questions")
        }
        guard let active = await workspace.activeQuestions(for: tab), active.id == payload.questionSetId else {
            return .error(409, "This question changed before the answer was sent")
        }
        let input: String
        do {
            input = try Self.questionAnswerInput(
                questions: active.questions,
                selections: payload.selections,
                customAnswers: payload.customAnswers ?? []
            )
        } catch {
            return .error(409, error.message)
        }
        return await deliver(input, to: id, sessionID: sessionID, preview: "Answered an interactive agent question")
    }

    private struct AgentControlRequest: Decodable {
        var ptyId: String
        var action: String
    }

    private func agentControl(_ request: RemoteRequest, sessionID: Int) async -> RemoteResponse {
        guard let payload = Self.decode(AgentControlRequest.self, request.body),
              let id = Self.terminalID(payload.ptyId) else { return .badRequest }
        guard let tab = await workspace.sharedTab(id) else { return .notShared }
        guard tab.isControllableAgent else {
            return .error(409, "Only Codex and Claude Code can be controlled remotely")
        }
        guard payload.action == "interrupt" else {
            return .error(400, "Unknown agent control action")
        }
        return await deliver("\u{03}", to: id, sessionID: sessionID, preview: "Interrupted the active agent turn")
    }

    private struct MessageRequest: Decodable {
        var ptyId: String
        var text: String
    }

    private func message(_ request: RemoteRequest, sessionID: Int) async -> RemoteResponse {
        guard let payload = Self.decode(MessageRequest.self, request.body),
              let id = Self.terminalID(payload.ptyId) else { return .badRequest }
        let text = RemoteText.sanitize(payload.text).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= RemoteLimits.maxMessage else {
            return .error(400, "Message is empty or too large")
        }
        guard let tab = await workspace.sharedTab(id) else { return .notShared }
        if tab.isShell, !(await hub.shellInputAllowed) {
            return .error(403, "Sending commands to shell terminals is disabled")
        }
        return await deliver(text + "\r", to: id, sessionID: sessionID, preview: text)
    }

    /// Types `input` into the tab and tells the app which device sent it.
    private func deliver(_ input: String, to terminalID: String, sessionID: Int, preview: String) async -> RemoteResponse {
        do {
            try await terminals.write(terminalID: terminalID, text: input)
        } catch {
            switch error {
            case .notFound: return .error(404, "Terminal not found")
            case .notRunning: return .error(409, "This terminal is not running")
            case .failed: return .badRequest
            }
        }
        let deviceName = await hub.deviceName(sessionID)
        RemoteLog.logger.info("device \(sessionID, privacy: .public) sent \(input.utf8.count, privacy: .public) bytes to a shared terminal")
        hub.emit(.message(RemoteMessageEvent(terminalID: terminalID, deviceID: sessionID, deviceName: deviceName, preview: preview)))
        return .noContent
    }

    // MARK: Static files

    private func staticAsset(_ path: String) async -> RemoteResponse {
        // Only the brand icon depends on the Mac's preferences.
        let iconTheme = path == "/brand-icon.png"
            ? await workspace.appearance().normalized.appIconTheme
            : RemoteAppearance.defaultTheme
        return await assets.asset(at: path, appIconTheme: iconTheme)?.response ?? .notFound
    }

    // MARK: Helpers

    private static func decode<Value: Decodable>(_ type: Value.Type, _ body: Data) -> Value? {
        try? JSONDecoder().decode(type, from: body)
    }

    /// A non-empty id of sane length, free of control characters.
    static func terminalID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= maxTerminalID,
              RemoteText.sanitize(value) == value else { return nil }
        return value
    }

    public struct AnswerError: Error, Equatable, Sendable {
        public var message: String
    }

    /// The keystrokes that pick an answer in the agent's question UI (upstream
    /// `question_answer_input`): per question, arrow-up past the top to anchor on the first
    /// option, arrow-down to each choice (Space toggles in multi-select), or down to "Other" and
    /// type the custom answer; Return confirms.
    public static func questionAnswerInput(
        questions: [RemoteQuestion],
        selections: [[Int]],
        customAnswers: [String?]
    ) throws(AnswerError) -> String {
        if questions.isEmpty || questions.count != selections.count
            || (!customAnswers.isEmpty && questions.count != customAnswers.count) {
            throw AnswerError(message: "The interactive question is no longer active")
        }
        let up = "\u{1B}[A"
        let down = "\u{1B}[B"
        var input = ""
        for (index, (question, selected)) in zip(questions, selections).enumerated() {
            let custom = (index < customAnswers.count ? customAnswers[index] : nil)
                .map { String(RemoteText.sanitize($0).trimmingCharacters(in: .whitespaces).prefix(maxCustomAnswer)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if (selected.isEmpty && custom == nil)
                || (!question.multiSelect && selected.count != 1 && custom == nil)
                || (!selected.isEmpty && custom != nil) {
                throw AnswerError(message: "Select an answer for every question")
            }
            let unique = Array(Set(selected)).sorted()
            if unique.count != selected.count || unique.contains(where: { $0 < 0 || $0 >= question.options.count }) {
                throw AnswerError(message: "An answer option is invalid")
            }
            let anchor = String(repeating: up, count: question.options.count + 2)
            if let custom {
                input += anchor + String(repeating: down, count: question.options.count) + "\r" + custom
            } else if question.multiSelect {
                for option in unique {
                    input += anchor + String(repeating: down, count: option) + " "
                }
            } else {
                input += anchor + String(repeating: down, count: unique[0])
            }
            input += "\r"
        }
        return input
    }
}

extension RemoteResponse {
    /// Upstream's answer to a request it could not parse.
    static let badRequest = RemoteResponse.error(400, "Bad request")
    static let notShared = RemoteResponse.error(403, "This terminal is not available remotely")
}
