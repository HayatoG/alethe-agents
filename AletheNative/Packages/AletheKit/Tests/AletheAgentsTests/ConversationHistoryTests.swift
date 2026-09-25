import Foundation
import Testing
@testable import AletheAgents

/// Conversation history (P3-7; upstream `list_claude_sessions`, `get_codex_session_title`).
@Suite struct ConversationHistoryTests {
    private func temporaryHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appending(path: "alethe-history-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    @Test func claudeTranscriptsGiveTitlePromptAndCount() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/\(ClaudeSessions.projectFolderName(for: "/repo"))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"  Fix the login bug  "}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Login bug fix"}"#,
            #"{"type":"user","message":{"content":"thanks"}}"#,
            #"{"type":"summary"}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(filePath: "\(folder)/abc.jsonl"))
        let found = ConversationHistory.claude(cwd: "/repo", homeDirectory: home)
        #expect(found.count == 1)
        #expect(found.first?.title == "Login bug fix")
        #expect(found.first?.firstPrompt == "Fix the login bug")
        #expect(found.first?.messageCount == 3)
    }

    @Test func codexTitlesSkipInjectedBlocks() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.codex/sessions/2026/09/24"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s1","cwd":"/repo"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add dark mode"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(filePath: "\(folder)/rollout-1-s1.jsonl"))
        let found = ConversationHistory.codex(cwd: "/repo", homeDirectory: home)
        #expect(found.map(\.id) == ["s1"])
        #expect(found.first?.firstPrompt == "Add dark mode")
        #expect(ConversationHistory.codex(cwd: "/other", homeDirectory: home).isEmpty)
    }

    @Test func readerSkipsOversizedLinesAndStopsWhenAsked() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "alethe-jsonl-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let huge = String(repeating: "x", count: JSONLReader.maxLineBytes + 10)
        try Data("first\n\(huge)\nthird\nfourth".utf8).write(to: URL(filePath: path))
        var lines: [String] = []
        JSONLReader.forEachLine(atPath: path) { lines.append(String(decoding: $0, as: UTF8.self)); return true }
        #expect(lines == ["first", "third", "fourth"])
        var first: [String] = []
        JSONLReader.forEachLine(atPath: path, maxLines: 1) { first.append(String(decoding: $0, as: UTF8.self)); return true }
        #expect(first == ["first"])
    }

    @Test func longPromptsAreTruncated() {
        let long = String(repeating: "a", count: 500)
        #expect(ConversationHistory.truncated(long).count == ConversationHistory.promptLimit)
    }

    @Test func titlesComeFromTheSessionTranscript() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/\(ClaudeSessions.projectFolderName(for: "/repo"))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"content":"Write the README"}}"#.utf8).write(to: URL(filePath: "\(folder)/s9.jsonl"))
        #expect(ConversationHistory.title(.claude, sessionID: "s9", cwd: "/repo", homeDirectory: home) == "Write the README")
        #expect(ConversationHistory.title(.claude, sessionID: "../x", cwd: "/repo", homeDirectory: home) == nil)
        #expect(ConversationHistory.title(.shell, sessionID: "s9", cwd: "/repo", homeDirectory: home) == nil)
    }
}
