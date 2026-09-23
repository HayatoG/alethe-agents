import Testing
@testable import AletheAgents

@Suite struct AgentRegistryTests {
    let registry = AgentRegistry.builtin

    @Test func phaseOneAgentsAreRegistered() {
        #expect(registry.kinds == [.claude, .codex, .opencode, .cursor, .shell])
        #expect(registry.descriptor(for: .cursor)?.cliCommand == "cursor-agent")
        #expect(registry.descriptor(for: .shell)?.isShell == true)
    }

    @Test func unrestrictedFlagsMatchUpstream() {
        #expect(registry.descriptor(for: .claude)?.unrestrictedFlag == "--dangerously-skip-permissions")
        #expect(registry.descriptor(for: .codex)?.unrestrictedFlag == "--dangerously-bypass-approvals-and-sandbox")
        #expect(registry.descriptor(for: .opencode)?.unrestrictedFlag == "--dangerously-skip-permissions")
        #expect(registry.descriptor(for: .cursor)?.unrestrictedFlag == "--force")
        #expect(registry.descriptor(for: .shell)?.unrestrictedFlag == nil)
    }

    @Test func parsesCaseInsensitivelyAndRejectsUnknown() {
        #expect(registry.parse(" Claude ") == .claude)
        #expect(registry.parse("codex") == .codex)
        #expect(registry.parse("wsl") == nil)
        #expect(registry.parse("") == nil)
        #expect(registry.parse(nil) == nil)
    }

    @Test func enabledKindsKeepRegistryOrderAndTheShell() {
        #expect(registry.enabledKinds(nil) == registry.kinds)
        #expect(registry.enabledKinds(["codex", "claude", "bogus"]) == [.claude, .codex, .shell])
        #expect(registry.enabledKinds([]) == [.shell])
    }
}
