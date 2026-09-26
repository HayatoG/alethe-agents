import Foundation
import Testing
@testable import AletheRemote

// MARK: - Fakes

final class FakeTerminals: RemoteTerminalSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [(String, String)] = []
    var scrollback = "prompt> "
    var sizes: [String: RemoteTerminalSize] = [:]
    var writeError: RemoteInputError?

    var writes: [(String, String)] { lock.withLock { _writes } }

    func scrollbackTail(terminalID: String, maxBytes: Int) async -> String { scrollback }

    func size(terminalID: String) async -> RemoteTerminalSize? { sizes[terminalID] }

    func write(terminalID: String, text: String) async throws(RemoteInputError) {
        if let writeError { throw writeError }
        lock.withLock { _writes.append((terminalID, text)) }
    }

    func output() -> AsyncStream<RemoteTerminalOutput> { AsyncStream { $0.finish() } }
}

final class FakeWorkspace: RemoteWorkspaceSource, @unchecked Sendable {
    var tabs: [RemoteSharedTab] = [
        RemoteSharedTab(terminalID: "claude-1", agent: "claude", cwd: "/tmp/p", sessionID: "s1"),
        RemoteSharedTab(terminalID: "shell-1", agent: "shell", cwd: "/tmp/p", sessionID: nil),
        RemoteSharedTab(terminalID: "open-1", agent: "opencode", cwd: "/tmp/p", sessionID: nil),
    ]
    var appearanceValue = RemoteAppearance.fallback
    var questions: RemoteQuestionSet?
    var transcriptFails = false

    func sharedTabs() async -> [RemoteSharedTab] { tabs }

    func snapshot() async -> RemoteWorkspaceSnapshot {
        RemoteWorkspaceSnapshot(groups: [], projects: [
            .init(id: "p", name: "Project", groupId: nil, color: nil, chats: [
                .init(id: "t1", ptyId: "claude-1", name: "Terminal", agent: "claude", terminalId: "pane"),
            ]),
        ])
    }

    func appearance() async -> RemoteAppearance { appearanceValue }

    struct Failure: Error {}

    func transcript(for tab: RemoteSharedTab, since: UInt64?, limit: Int) async throws -> RemoteTranscript {
        if transcriptFails { throw Failure() }
        return RemoteTranscript(sessionId: tab.sessionID, revision: 42, unchanged: since == 42,
                                messages: since == 42 ? [] : [.init(role: "user", text: "hi")])
    }

    func activeQuestions(for tab: RemoteSharedTab) async -> RemoteQuestionSet? { questions }
}

struct FakeAssets: RemoteAssetSource {
    func asset(at path: String, appIconTheme: String) async -> RemoteAsset? {
        switch path {
        case "/", "/index.html": RemoteAsset(data: Data("<html>".utf8), contentType: "text/html; charset=utf-8", caching: .noStore)
        case "/brand-icon.png": RemoteAsset(data: Data(appIconTheme.utf8), contentType: "image/png", caching: .noStore)
        default: nil
        }
    }
}

private let peer = "192.168.1.50:51000"
private let scopeQuestion = RemoteQuestion(
    id: "scope", header: "Scope", question: "Which scope?", multiSelect: false,
    options: [.init(label: "Focused", description: ""), .init(label: "Broad", description: "")]
)

private struct Harness {
    let clock = TestClock()
    let hub: RemoteHub
    let terminals = FakeTerminals()
    let workspace = FakeWorkspace()
    let api: RemoteAPI

    init() {
        let clock = clock
        hub = RemoteHub(resolver: RemoteHostResolver(lanAddress: { "192.168.1.20" }, tailscaleAddress: { nil }), now: { clock.now })
        api = RemoteAPI(hub: hub, terminals: terminals, workspace: workspace, assets: FakeAssets())
    }

    /// Opens pairing and pairs one device through the API; returns its session token.
    func pairDevice() async throws -> String {
        await hub.beginRun()
        await hub.openPairingWindow()
        let token = await hub.pairingToken
        let response = await api.route(post("/api/pair", ["token": token, "deviceName": "Phone"], token: nil))
        #expect(response.status == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try #require(object["sessionToken"] as? String)
    }

    func get(_ target: String, token: String?) -> RemoteRequest {
        RemoteRequest(method: "GET", target: target, headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:], peerAddress: peer)
    }

    func post(_ target: String, _ body: [String: Any], token: String?) -> RemoteRequest {
        RemoteRequest(
            method: "POST", target: target,
            headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:],
            body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(),
            peerAddress: peer
        )
    }
}

private func json(_ response: RemoteResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
}

// MARK: - Upstream goldens

/// Upstream `remote/http.rs` and `remote/appearance.rs` tests.
struct RemoteAPIGoldenTests {
    @Test func interactiveAnswersBecomeTerminalNavigation() throws {
        let questions = [scopeQuestion]
        let input = try RemoteAPI.questionAnswerInput(questions: questions, selections: [[1]], customAnswers: [])
        #expect(input.hasSuffix("\u{1B}[B\r"))
        #expect(throws: RemoteAPI.AnswerError.self) {
            try RemoteAPI.questionAnswerInput(questions: questions, selections: [[2]], customAnswers: [])
        }
        #expect(throws: RemoteAPI.AnswerError.self) {
            try RemoteAPI.questionAnswerInput(questions: questions, selections: [], customAnswers: [])
        }
        let custom = try RemoteAPI.questionAnswerInput(questions: questions, selections: [[]], customAnswers: ["A custom scope"])
        #expect(custom.hasSuffix("\u{1B}[B\u{1B}[B\rA custom scope\r"))
    }

    @Test func appearanceDefaultsAreSafeAndBranded() {
        #expect(RemoteAppearance.resolved(uiTheme: nil, appIconTheme: nil, language: nil, motionPreference: nil) == RemoteAppearance(
            uiTheme: "elite-indigo", appIconTheme: "elite-indigo", language: "en",
            motionPreference: "animated", colorScheme: "dark"
        ))
    }

    @Test func appearanceAcceptsPersistedLightPreferences() {
        #expect(RemoteAppearance.resolved(
            uiTheme: "elite-blush", appIconTheme: "elite-original", language: "pt-BR", motionPreference: "reduced"
        ) == RemoteAppearance(
            uiTheme: "elite-blush", appIconTheme: "elite-original", language: "pt-BR",
            motionPreference: "reduced", colorScheme: "light"
        ))
    }

    @Test func appearanceRejectsUnknownPersistedValues() {
        let appearance = RemoteAppearance.resolved(
            uiTheme: "custom-script", appIconTheme: "missing-icon", language: "unknown", motionPreference: "spin"
        )
        #expect(appearance.uiTheme == "elite-indigo")
        #expect(appearance.appIconTheme == "elite-indigo")
        #expect(appearance.language == "en")
        #expect(appearance.motionPreference == "animated")
    }
}

// MARK: - Routes

struct RemoteAPIRouteTests {
    @Test func badPairingTokenIs401AndRecordsAFailure() async {
        let harness = Harness()
        await harness.hub.beginRun()
        await harness.hub.openPairingWindow()
        for _ in 0..<RemoteLimits.authFailureLimit {
            let response = await harness.api.route(harness.post("/api/pair", ["token": "wrong"], token: nil))
            #expect(response.status == 401)
        }
        #expect(await harness.hub.authBlocked(peer))
        #expect(await harness.api.route(harness.get("/", token: nil)).status == 429)
    }

    @Test func pairingReturnsASessionAndInfo() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        #expect(token.count == RemoteLimits.sessionTokenLength)
        let info = await harness.api.route(harness.get("/api/info", token: token))
        #expect(info.status == 200)
        #expect(json(info)["readOnly"] as? Bool == false)
        #expect(json(info).keys.contains("wsUrl"))
    }

    @Test func apiRoutesNeedAValidSession() async {
        let harness = Harness()
        for path in ["/api/info", "/api/state", "/api/scrollback?id=claude-1", "/api/transcript?id=claude-1"] {
            #expect(await harness.api.route(harness.get(path, token: nil)).status == 401)
            #expect(await harness.api.route(harness.get(path, token: "not-a-session")).status == 401)
        }
        let message = await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "hi"], token: "nope"))
        #expect(message.status == 401)
        #expect(harness.terminals.writes.isEmpty)
    }

    @Test func appearanceIsNormalizedWithoutASession() async {
        let harness = Harness()
        harness.workspace.appearanceValue = RemoteAppearance(
            uiTheme: "<script>", appIconTheme: "elite-blush", language: "fr", motionPreference: "reduced", colorScheme: "light"
        )
        let response = await harness.api.route(harness.get("/appearance.json", token: nil))
        #expect(response.status == 200)
        #expect(json(response)["uiTheme"] as? String == "elite-indigo")
        #expect(json(response)["colorScheme"] as? String == "dark")
        #expect(json(response)["appIconTheme"] as? String == "elite-blush")
    }

    @Test func stateListsTheSnapshot() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        let response = await harness.api.route(harness.get("/api/state", token: token))
        #expect(response.status == 200)
        let projects = try #require(json(response)["projects"] as? [[String: Any]])
        #expect((projects.first?["chats"] as? [[String: Any]])?.count == 1)
    }

    @Test func scrollbackIsForbiddenUnlessSharedAndSubscribes() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        #expect(await harness.api.route(harness.get("/api/scrollback?id=private", token: token)).status == 403)
        #expect(await harness.api.route(harness.get("/api/scrollback", token: token)).status == 400)

        harness.terminals.sizes["claude-1"] = RemoteTerminalSize(cols: 120, rows: 40)
        let response = await harness.api.route(harness.get("/api/scrollback?id=claude-1", token: token))
        #expect(response.status == 200)
        #expect(json(response)["cols"] as? Int == 120)
        #expect(json(response)["text"] as? String == "prompt> ")
        let session = try #require(await harness.hub.sessionID(for: token))
        #expect(await harness.hub.subscription(session) == "claude-1")

        let fallback = await harness.api.route(harness.get("/api/scrollback?id=shell-1", token: token))
        #expect(json(fallback)["cols"] as? Int == 80)
        #expect(json(fallback)["rows"] as? Int == 24)
    }

    @Test func transcriptForAgentsOnly() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        #expect(await harness.api.route(harness.get("/api/transcript?id=private", token: token)).status == 403)

        let shell = await harness.api.route(harness.get("/api/transcript?id=shell-1", token: token))
        #expect(json(shell)["supported"] as? Bool == false)

        let first = await harness.api.route(harness.get("/api/transcript?id=claude-1", token: token))
        #expect(json(first)["supported"] as? Bool == true)
        #expect(json(first)["agent"] as? String == "claude")
        #expect(json(first)["revision"] as? Int == 42)
        #expect((json(first)["messages"] as? [Any])?.count == 1)

        let unchanged = await harness.api.route(harness.get("/api/transcript?id=claude-1&since=42", token: token))
        #expect(json(unchanged)["unchanged"] as? Bool == true)

        harness.workspace.transcriptFails = true
        let failed = await harness.api.route(harness.get("/api/transcript?id=claude-1", token: token))
        #expect(failed.status == 200)
        #expect(json(failed)["error"] as? String == "Transcript is not available")
    }

    @Test func messageIsSanitizedAndEmitsAnEvent() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        let response = await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "  run\u{1B}[2J tests\n "], token: token))
        #expect(response.status == 204)
        #expect(harness.terminals.writes.first?.0 == "claude-1")
        #expect(harness.terminals.writes.first?.1 == "run [2J tests\r")

        var events = harness.hub.events.makeAsyncIterator()
        guard case .message(let event) = await events.next() else {
            Issue.record("expected a message event")
            return
        }
        #expect(event.terminalID == "claude-1")
        #expect(event.deviceName == "Phone")
        #expect(event.preview == "run [2J tests")
    }

    @Test func messagePreviewIsCappedAndSizeLimited() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        let long = String(repeating: "a", count: 500)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": long], token: token)).status == 204)
        var events = harness.hub.events.makeAsyncIterator()
        if case .message(let event) = await events.next() {
            #expect(event.preview.count == RemoteLimits.maxPreview)
        }
        let huge = String(repeating: "a", count: RemoteLimits.maxMessage + 1)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": huge], token: token)).status == 400)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": " \n "], token: token)).status == 400)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "private", "text": "x"], token: token)).status == 403)
    }

    @Test func shellInputNeedsPermission() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "shell-1", "text": "ls"], token: token)).status == 403)
        #expect(harness.terminals.writes.isEmpty)
        await harness.hub.setAllowShellInput(true)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "shell-1", "text": "ls"], token: token)).status == 204)
    }

    @Test func readOnlyRefusesEveryInput() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        await harness.hub.setReadOnly(true)
        harness.workspace.questions = RemoteQuestionSet(id: "call-1", questions: [scopeQuestion])
        let requests = [
            harness.post("/api/message", ["ptyId": "claude-1", "text": "hi"], token: token),
            harness.post("/api/agent-control", ["ptyId": "claude-1", "action": "interrupt"], token: token),
            harness.post("/api/question-answer", ["ptyId": "claude-1", "questionSetId": "call-1", "selections": [[0]]], token: token),
        ]
        for request in requests {
            #expect(await harness.api.route(request).status == 403)
        }
        #expect(harness.terminals.writes.isEmpty)
        #expect(await harness.api.route(harness.get("/api/scrollback?id=claude-1", token: token)).status == 200)
    }

    @Test func messageRateIsLimited() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        for _ in 0..<RemoteLimits.messageRateLimit {
            #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "x"], token: token)).status == 204)
        }
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "x"], token: token)).status == 429)
        harness.clock.advance(RemoteLimits.messageRateWindow + 1)
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "x"], token: token)).status == 204)
    }

    @Test func staleQuestionIs409() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        let answer = ["ptyId": "claude-1", "questionSetId": "call-1", "selections": [[1]]] as [String: Any]

        #expect(await harness.api.route(harness.post("/api/question-answer", answer, token: token)).status == 409)
        harness.workspace.questions = RemoteQuestionSet(id: "call-2", questions: [scopeQuestion])
        #expect(await harness.api.route(harness.post("/api/question-answer", answer, token: token)).status == 409)
        #expect(harness.terminals.writes.isEmpty)

        harness.workspace.questions = RemoteQuestionSet(id: "call-1", questions: [scopeQuestion])
        #expect(await harness.api.route(harness.post("/api/question-answer", answer, token: token)).status == 204)
        #expect(harness.terminals.writes.first?.1.hasSuffix("\u{1B}[B\r") == true)

        let invalid = ["ptyId": "claude-1", "questionSetId": "call-1", "selections": [[5]]] as [String: Any]
        #expect(await harness.api.route(harness.post("/api/question-answer", invalid, token: token)).status == 409)
        let shell = ["ptyId": "shell-1", "questionSetId": "call-1", "selections": [[0]]] as [String: Any]
        #expect(await harness.api.route(harness.post("/api/question-answer", shell, token: token)).status == 409)
    }

    @Test func interruptSendsCtrlCToAgentsOnly() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        #expect(await harness.api.route(harness.post("/api/agent-control", ["ptyId": "claude-1", "action": "interrupt"], token: token)).status == 204)
        #expect(harness.terminals.writes.first?.1 == "\u{03}")
        #expect(await harness.api.route(harness.post("/api/agent-control", ["ptyId": "open-1", "action": "interrupt"], token: token)).status == 409)
        #expect(await harness.api.route(harness.post("/api/agent-control", ["ptyId": "claude-1", "action": "kill"], token: token)).status == 400)
        #expect(await harness.api.route(harness.post("/api/agent-control", ["ptyId": "private", "action": "interrupt"], token: token)).status == 403)
    }

    @Test func notRunningTabIs409() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        harness.terminals.writeError = .notRunning
        #expect(await harness.api.route(harness.post("/api/message", ["ptyId": "claude-1", "text": "x"], token: token)).status == 409)
    }

    @Test func malformedBodiesAre400() async throws {
        let harness = Harness()
        let token = try await harness.pairDevice()
        var request = harness.post("/api/message", [:], token: token)
        request.body = Data("not json".utf8)
        #expect(await harness.api.route(request).status == 400)
        request.body = Data(count: RemoteLimits.maxBody + 1)
        #expect(await harness.api.route(request).status == 400)
    }

    @Test func staticPathsGoToTheAssetSource() async throws {
        let harness = Harness()
        harness.workspace.appearanceValue = RemoteAppearance.resolved(uiTheme: nil, appIconTheme: "elite-blush", language: nil, motionPreference: nil)
        let index = await harness.api.route(harness.get("/", token: nil))
        #expect(index.status == 200)
        #expect(index.sizeLimit == .large)
        let icon = await harness.api.route(harness.get("/brand-icon.png", token: nil))
        #expect(String(decoding: icon.body, as: UTF8.self) == "elite-blush")
        #expect(await harness.api.route(harness.get("/missing.js", token: nil)).status == 404)
        let token = try await harness.pairDevice()
        #expect(await harness.api.route(harness.get("/api/unknown", token: token)).status == 404)
    }
}
