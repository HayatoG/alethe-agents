import Testing
@testable import AletheAgents

/// Ported from upstream `src/lib/sessionLaunch.test.ts`.
@Suite struct AgentArgumentsTests {
    @Test func newClaudePanesGetDistinctSessionIDs() {
        let first = AgentArguments.build(for: .claude, base: ["--dangerously-skip-permissions"]) { "id-1" }
        let second = AgentArguments.build(for: .claude, base: ["--dangerously-skip-permissions"]) { "id-2" }
        #expect(first.arguments == ["--session-id", "id-1", "--dangerously-skip-permissions"])
        #expect(second.arguments == ["--session-id", "id-2", "--dangerously-skip-permissions"])
        #expect(first.createdSession && first.sessionID == "id-1")
    }

    @Test func claudeResumesOnlyItsOwnSession() {
        let launch = AgentArguments.build(
            for: .claude,
            base: ["--continue", "--resume", "stale", "--session-id", "stale-too", "--model", "sonnet"],
            sessionID: "pane-session")
        #expect(launch.arguments == ["--resume", "pane-session", "--model", "sonnet"])
        #expect(!launch.createdSession)
    }

    @Test func codexWithoutAnIDStartsANewChat() {
        #expect(AgentArguments.build(for: .codex, base: ["resume", "--last", "--search"]).arguments == ["--search"])
    }

    @Test func codexAndOpenCodeUseTheirResumeSyntax() {
        #expect(AgentArguments.build(for: .codex, base: ["resume", "old", "--search"], sessionID: "codex-pane").arguments
            == ["resume", "codex-pane", "--search"])
        #expect(AgentArguments.build(for: .opencode, base: ["--continue", "--session", "old", "--model", "x"],
                                     sessionID: "open-pane").arguments
            == ["--session", "open-pane", "--model", "x"])
    }

    @Test func cursorResumesItsChatAndDropsStaleFlags() {
        #expect(AgentArguments.build(for: .cursor, base: ["--continue", "--resume", "old", "--resume=older", "--force"],
                                     sessionID: "cursor-chat").arguments
            == ["--resume", "cursor-chat", "--force"])
        let fresh = AgentArguments.build(for: .cursor, base: ["--continue", "--force"])
        #expect(fresh.arguments == ["--force"])
        #expect(fresh.sessionID == nil)
    }

    @Test func shellKeepsItsArguments() {
        #expect(AgentArguments.build(for: .shell, base: ["-x"], sessionID: "ignored") == AgentArguments(arguments: ["-x"]))
    }

    @Test func antigravityResumesWithConversationAndDropsStaleFlags() {
        let resumed = AgentArguments.build(for: .antigravity, base: ["--conversation", "old", "-c", "--x"], sessionID: "abc")
        #expect(resumed.arguments == ["--conversation", "abc", "--x"])
        #expect(AgentArguments.build(for: .antigravity, base: ["--continue"]).arguments.isEmpty)
    }

    @Test func kiroRunsItsFlagsUnderChat() {
        #expect(AgentArguments.build(for: .kiro, base: ["--trust-all-tools"]).arguments == ["chat", "--trust-all-tools"])
    }

    @Test func agentsWithoutSessionsPassArgumentsThrough() {
        for kind in [AgentKind.copilot, .mimo, .freebuff] {
            #expect(AgentArguments.build(for: kind, base: ["--allow-all"]).arguments == ["--allow-all"])
        }
    }
}
