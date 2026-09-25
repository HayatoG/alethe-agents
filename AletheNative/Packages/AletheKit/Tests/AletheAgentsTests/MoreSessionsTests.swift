import Foundation
import Testing
@testable import AletheAgents

/// OpenCode, Antigravity and Cursor sessions (P3-6; upstream `opencode_sessions.rs`,
/// `antigravity_sessions.rs`, `cursor_sessions.rs`).
@Suite struct MoreSessionsTests {
    @Test func openCodeListsSessionsOfTheFolderNewestFirst() {
        let json = """
        Loading…
        [{"id":"ses_old","updated":1000,"directory":"/repo"},
         {"id":"ses_new","updated":5000,"directory":"/repo/"},
         {"id":"ses_other","updated":9000,"directory":"/elsewhere"},
         {"updated":7000}]
        """
        let sessions = OpenCodeSessions.parse(json, cwd: "/repo")
        #expect(sessions.map(\.id) == ["ses_new", "ses_old"])
        #expect(sessions.first?.modifiedAt == Date(timeIntervalSince1970: 5))
        #expect(OpenCodeSessions.parse("not json", cwd: "/repo").isEmpty)
    }

    @Test func antigravityMatchesWorkspacesAroundTheFolder() {
        let json = """
        {"conversations": {
          "a": {"summary": {"Preview": "fix tests", "WorkspaceURIs": ["file:///repo"], "UpdatedAt": "2026-09-20T10:00:00Z"}},
          "b": {"summary": {"WorkspaceURIs": ["file:///repo/sub"]}, "last_modified_time": "2026-09-21T10:00:00.500Z"},
          "c": {"summary": {"WorkspaceURIs": ["file:///repo2"]}},
          "d": {"summary": {"WorkspaceURIs": ["file:///my%20folder"]}}
        }}
        """
        let found = AntigravitySessions.parse(Data(json.utf8), cwd: "/repo")
        #expect(found.map(\.session.id) == ["b", "a"], "a subfolder counts; /repo2 does not")
        #expect(found.last?.preview == "fix tests")
        #expect(AntigravitySessions.parse(Data(json.utf8), cwd: "/my folder").map(\.session.id) == ["d"])
    }

    @Test func cursorChatIDsAreStrict() {
        #expect(CursorChats.chatID(in: "Creating chat...\n\n8f1d4c2a-6b7e-4a19-9c30-2f5ab8d17e04\n")
                == "8f1d4c2a-6b7e-4a19-9c30-2f5ab8d17e04")
        #expect(CursorChats.chatID(in: "0a0009211687cf0429b1d3e8f7c25a61\n") == "0a0009211687cf0429b1d3e8f7c25a61")
        for bad in ["not logged in\n", "", "--resume\n", "abc123\n"] {
            #expect(CursorChats.chatID(in: bad) == nil)
        }
        #expect(!CursorChats.isSignedIn(statusOutput: "Not logged in"))
        #expect(CursorChats.isSignedIn(statusOutput: "✓ Logged in as me@example.com"))
    }

    @Test func discoveryCoversTheAgentsThatRecordSessionsLater() {
        #expect(SessionResume.discoversNewSessions(.codex) && SessionResume.discoversNewSessions(.opencode)
                && SessionResume.discoversNewSessions(.antigravity))
        #expect(!SessionResume.discoversNewSessions(.cursor), "Cursor creates its chat before the launch")
        #expect(!SessionResume.discoversNewSessions(.claude), "Claude takes an id up front")
    }
}
