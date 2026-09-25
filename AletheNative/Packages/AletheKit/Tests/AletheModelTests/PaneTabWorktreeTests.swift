import Foundation
import Testing
@testable import AletheModel

@Suite struct PaneTabWorktreeTests {
    @Test func olderJSONWithoutWorktreeFieldsDecodes() throws {
        let tab = PaneTab(agent: "claude", workingDirectory: "/p")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object.removeValue(forKey: "worktreeAgentID")
        object.removeValue(forKey: "worktreeBranch")
        let decoded = try JSONDecoder().decode(PaneTab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.worktreeAgentID == nil)
        #expect(decoded.worktreeBranch == nil)
        #expect(decoded.agent == "claude")
    }

    @Test func worktreeFieldsRoundTrip() throws {
        let tab = PaneTab(agent: "codex", worktreeAgentID: "abc", worktreeBranch: "alethe/agent-abc")
        let decoded = try JSONDecoder().decode(PaneTab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
    }
}
