import Foundation
import Testing
@testable import AletheAgents

@Suite struct ClaudeTranscriptsTests {
    @Test func findsATranscriptInAnyProjectFolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "alethe-claude-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/-private-tmp"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(folder)/abc.jsonl", contents: Data("{}\n".utf8))

        #expect(ClaudeTranscripts.exists(sessionID: "abc", homeDirectory: home))
        #expect(!ClaudeTranscripts.exists(sessionID: "never-started", homeDirectory: home))
        #expect(!ClaudeTranscripts.exists(sessionID: "../-private-tmp/abc", homeDirectory: home))
        #expect(!ClaudeTranscripts.exists(sessionID: "abc", homeDirectory: "/nonexistent"))
    }
}
