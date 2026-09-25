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
        #expect(draft.redactions == 1 && !draft.content.contains("supersecretvalue"))
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
}
