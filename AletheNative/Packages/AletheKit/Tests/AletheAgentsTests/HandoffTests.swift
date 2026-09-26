import Foundation
import Testing
@testable import AletheAgents

/// Claude Code ↔ Codex handoff (P3-12; upstream `handoff.rs` tests).
@Suite struct HandoffTests {
    @Test func redactsCommonSecrets() {
        let (output, count) = Handoff.redact("Authorization: Bearer abcdefgh\nOPENAI_API_KEY=sk-proj-abcdefghijklmnop\n")
        #expect(count >= 2)
        #expect(!output.contains("abcdefghijklmnop") && output.contains("[REDACTED]"))
    }

    @Test func capsulePrioritizesUserRequests() {
        let events = [Handoff.Event(.user, "Build the feature"), Handoff.Event(.assistant, "Implemented parser"),
                      Handoff.Event(.tool, "cargo test"), Handoff.Event(.user, "Keep the old terminal open")]
        let (capsule, _) = Handoff.capsule(source: .claude, target: .codex, sessionID: "session-1", cwd: "/repo",
                                           events: events, workspace: "- Git repository: not detected")
        #expect(capsule.contains("## Original task\n\nBuild the feature"))
        #expect(capsule.contains("## Latest user request\n\nKeep the old terminal open"))
        #expect(capsule.contains("Private reasoning"))
    }

    @Test func claudeEventsSkipSideChainsAndKeepTools() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "alethe-handoff-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = [
            #"{"type":"user","message":{"content":"Fix it"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"a.txt"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(filePath: path))
        let events = Handoff.claudeEvents(atPath: path)
        #expect(events.map(\.role) == [.user, .assistant, .tool, .toolResult])
        #expect(events[2].text == #"Bash: {"command":"ls"}"#)
    }

    @Test func preparingNeedsAConversationWithUserMessages() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "alethe-handoff-home-\(UUID().uuidString)").path
        let repo = FileManager.default.temporaryDirectory.appending(path: "alethe-handoff-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: repo) }
        #expect(Handoff.prepare(source: .claude, target: .claude, sessionID: nil, cwd: repo, homeDirectory: home) == .failure(.sameAgent))
        #expect(Handoff.prepare(source: .shell, target: .codex, sessionID: nil, cwd: repo, homeDirectory: home) == .failure(.unsupported))
        #expect(Handoff.prepare(source: .claude, target: .codex, sessionID: "x", cwd: repo, homeDirectory: home) == .failure(.noSession))
        let folder = "\(home)/.claude/projects/\(ClaudeSessions.projectFolderName(for: repo))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"content":"Add login with token=supersecretvalue"}}"#.utf8)
            .write(to: URL(filePath: "\(folder)/s1.jsonl"))
        guard case .success(let draft) = Handoff.prepare(source: .claude, target: .codex, sessionID: "s1", cwd: repo, homeDirectory: home) else {
            Issue.record("no draft"); return
        }
        #expect(draft.title.hasPrefix("Add login") && !draft.usedNewest)
        // The request appears in more than one section of the capsule; each copy is redacted.
        #expect(draft.redactions >= 1)
        #expect(!draft.content.contains("supersecretvalue"))
    }

    @Test func materializesAndPrunesCapsules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "alethe-handoffs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try Handoff.materialize("# capsule", in: root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# capsule")
        #expect(throws: (any Error).self) { try Handoff.materialize(String(repeating: "x", count: Handoff.materializedByteLimit + 1), in: root) }
        Handoff.pruneOld(in: root, now: Date().addingTimeInterval(8 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Remote questions and transcript snapshots (P7-3)

    @Test func parsesCodexAndClaudeQuestions() throws {
        let codex = try #require(Handoff.remoteQuestions(
            toolName: "request_user_input",
            input: #"{"questions":[{"id":"scope","header":"Scope","question":"Which scope?","options":[{"label":"Focused","description":"Only Codex and Claude"}]}]}"#))
        #expect(codex[0].id == "scope")
        #expect(!codex[0].multiSelect)

        let claude = try #require(Handoff.remoteQuestions(toolName: "AskUserQuestion", input: [
            "questions": [[
                "header": "Files",
                "question": "Which files?",
                "multiSelect": true,
                "options": [
                    ["label": "Source", "description": "Application code"],
                    ["label": "Tests", "description": "Test code"],
                ],
            ]],
        ] as [String: Any]))
        #expect(claude[0].multiSelect)
        #expect(claude[0].options.count == 2)
        #expect(claude[0].id == "question-1")
        #expect(Handoff.remoteQuestions(toolName: "Bash", input: ["questions": []] as [String: Any]) == nil)
    }

    @Test func preservesAgentCallIDsForRemoteQuestions() throws {
        let codexPath = try Self.fixture(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-codex-42","arguments":"{\"questions\":[{\"id\":\"scope\",\"header\":\"Scope\",\"question\":\"Which scope?\",\"options\":[{\"label\":\"Focused\",\"description\":\"Only this area\"}]}]}"}}"#)
        let claudePath = try Self.fixture(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu-claude-42","name":"AskUserQuestion","input":{"questions":[{"header":"Scope","question":"Which scope?","multiSelect":false,"options":[{"label":"Focused","description":"Only this area"}]}]}}]}}"#)
        defer { try? FileManager.default.removeItem(atPath: codexPath); try? FileManager.default.removeItem(atPath: claudePath) }
        let codex = Handoff.codexEvents(atPath: codexPath)
        let claude = Handoff.claudeEvents(atPath: claudePath)
        #expect(codex[0].questionSetID == "call-codex-42")
        #expect(claude[0].questionSetID == "toolu-claude-42")
        #expect(claude[0].role == .question && claude[0].text == "Scope: Which scope? (Focused)")
    }

    @Test func unchangedRevisionSkipsTheParse() throws {
        let (home, repo) = try Self.claudeSession(lines: [#"{"type":"user","message":{"content":"Hello"}}"#])
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: repo) }
        let first = Handoff.transcriptSnapshot(agent: .claude, folder: repo, session: "s1", since: nil, homeDirectory: home)
        #expect(first.sessionID == "s1" && !first.unchanged && first.revision > 0)
        #expect(first.messages.map(\.text) == ["Hello"])
        let second = Handoff.transcriptSnapshot(agent: .claude, folder: repo, session: "s1", since: first.revision, homeDirectory: home)
        #expect(second.unchanged && second.messages.isEmpty && second.revision == first.revision)
        let missing = Handoff.transcriptSnapshot(agent: .claude, folder: repo + "-gone", session: "s1", since: nil, homeDirectory: home)
        #expect(missing.sessionID == nil && missing.revision == 0 && missing.messages.isEmpty)
    }

    @Test func limitKeepsTheNewestAndRedacts() throws {
        let lines = (1...5).map { #"{"type":"user","message":{"content":"Message \#($0)"}}"# }
            + [#"{"type":"user","message":{"content":"API_TOKEN=supersecretvalue"}}"#]
        let (home, repo) = try Self.claudeSession(lines: lines)
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: repo) }
        let snapshot = Handoff.transcriptSnapshot(agent: .claude, folder: repo, session: "s1", since: nil, limit: 2, homeDirectory: home)
        #expect(snapshot.messages.count == 2)
        #expect(snapshot.messages[0].text == "Message 5")
        #expect(!snapshot.messages[1].text.contains("supersecretvalue"))
    }

    @Test func activeQuestionsComeFromTheLastEvent() throws {
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu-1","name":"AskUserQuestion","input":{"questions":[{"header":"Scope","question":"Which scope?","options":[{"label":"A"},{"label":"B"}]}]}}]}}"#
        let (home, repo) = try Self.claudeSession(lines: [#"{"type":"user","message":{"content":"Go"}}"#, question])
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: repo) }
        let active = try #require(Handoff.activeQuestions(agent: .claude, folder: repo, session: "s1", homeDirectory: home))
        #expect(active.id == "toolu-1" && active.questions[0].options.map(\.label) == ["A", "B"])
        let folder = "\(home)/.claude/projects/\(ClaudeSessions.projectFolderName(for: repo))"
        try Data([#"{"type":"user","message":{"content":"Go"}}"#, question, #"{"type":"user","message":{"content":"Done"}}"#]
            .joined(separator: "\n").utf8).write(to: URL(filePath: "\(folder)/s1.jsonl"))
        #expect(Handoff.activeQuestions(agent: .claude, folder: repo, session: "s1", homeDirectory: home) == nil)
    }

    private static func fixture(_ line: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "alethe-question-\(UUID().uuidString).jsonl").path
        try Data(line.utf8).write(to: URL(filePath: path))
        return path
    }

    /// A temporary home with one Claude Code session `s1` for a temporary repository.
    private static func claudeSession(lines: [String]) throws -> (home: String, repo: String) {
        let home = FileManager.default.temporaryDirectory.appending(path: "alethe-remote-home-\(UUID().uuidString)").path
        let repo = FileManager.default.temporaryDirectory.appending(path: "alethe-remote-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let folder = "\(home)/.claude/projects/\(ClaudeSessions.projectFolderName(for: repo))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(filePath: "\(folder)/s1.jsonl"))
        return (home, repo)
    }
}
