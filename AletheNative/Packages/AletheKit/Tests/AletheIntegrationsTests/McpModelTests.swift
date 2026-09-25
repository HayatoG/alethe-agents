import AletheAgents
import Foundation
import Testing
@testable import AletheIntegrations

func stdioServer(_ name: String) -> McpServer {
    McpServer(name: name, transport: .stdio(command: "node", arguments: ["server.js"], cwd: nil))
}

/// Upstream `mcp_model.rs` tests plus the masking and per-launch alignment.
@Suite struct McpModelTests {
    @Test func agentParsingAcceptsTheCLINames() {
        #expect(McpAgent(parsing: "agy") == .antigravity)
        #expect(McpAgent(parsing: "Antigravity") == .antigravity)
        #expect(McpAgent(parsing: "cursor-agent") == .cursor)
        #expect(McpAgent(parsing: " codex ") == .codex)
        #expect(McpAgent(parsing: "shell") == nil)
        #expect(McpSourceKind(parsing: "LOCAL") == .local)
        #expect(McpSourceKind(parsing: "team") == nil)
    }

    @Test func agentsMapToAgentKinds() {
        for agent in McpAgent.allCases {
            #expect(McpAgent(kind: agent.agentKind) == agent)
        }
        #expect(McpAgent(kind: .shell) == nil)
        #expect(McpAgent(kind: .copilot) == nil)
    }

    @Test func anEntryCanBeLiteralAndPassthroughAtOnce() {
        let entry = McpEnvEntry(literal: "1", passthroughFrom: "QUADRANT")
        #expect(entry.view.literal != nil)
        #expect(entry.view.passthroughFrom == "QUADRANT")
    }

    @Test func literalEnvNeverLeaksThroughTheView() {
        var server = stdioServer("probe")
        server.env["DISCORD_TOKEN"] = .literal("super-secret-token-value")
        let view = server.view
        #expect(view.env["DISCORD_TOKEN"]?.literal?.preview == "••••••••alue")
        #expect(view.env["DISCORD_TOKEN"]?.literal?.isEmpty == false)
        #expect(!String(describing: view).contains("super-secret-token"))
    }

    @Test func headersAreMaskedInTheView() {
        let server = McpServer(name: "gh", transport: .http(url: "https://x", headers: ["Authorization": .literal("Bearer ghp-secret-value-1234")]))
        guard case .http(_, let headers) = server.view.transport else {
            Issue.record("expected http")
            return
        }
        #expect(headers["Authorization"]?.literal?.preview == "••••••••1234")
        #expect(McpEnvEntry.literal("").view.literal == McpLiteralView(preview: "", isEmpty: true))
    }

    @Test func descriptionsAndDumpsNeverShowALiteral() {
        var server = McpServer(name: "gh", transport: .sse(url: "https://x", headers: ["Authorization": .literal("Bearer header-secret-value")]))
        server.env["TOKEN"] = .literal("env-secret-value-abcd")
        server.env["PASS"] = .passthrough("PASS")
        var dumped = ""
        dump(server, to: &dumped)
        for text in [String(describing: server), String(reflecting: server), dumped, "\(server.env)"] {
            #expect(!text.contains("header-secret"))
            #expect(!text.contains("env-secret"))
        }
        #expect(String(describing: server.env["PASS"]!).contains("passthrough: PASS"))
    }

    @Test func passthroughEnvIsUnsupportedOnClaudeButFineOnCodex() {
        var server = stdioServer("probe")
        server.env["TOKEN"] = .passthrough("TOKEN")

        let blocked = server.unsupportedFields(for: .claude)
        #expect(blocked == [McpUnsupportedField(agent: .claude, field: "env.TOKEN", detail: "TOKEN")])
        #expect(server.unsupportedFields(for: .codex).isEmpty)
        #expect(server.unsupportedFields(for: .opencode).isEmpty)
    }

    @Test func timeoutsOnlySurviveOnCodex() {
        var server = stdioServer("probe")
        server.timeouts = McpTimeouts(startupSeconds: 30)
        #expect(server.unsupportedFields(for: .codex).isEmpty)
        #expect(server.unsupportedFields(for: .opencode).map(\.field) == ["timeouts"])
    }

    @Test func aPassthroughHeaderBlocksACopyToAnAgentThatCannotLateBind() {
        let server = McpServer(
            name: "gh",
            transport: .http(url: "https://api.githubcopilot.com/mcp", headers: ["Authorization": .passthrough("GH_TOKEN")])
        )
        let blocked = server.unsupportedFields(for: .claude)
        #expect(blocked.map(\.field) == ["headers.Authorization"])
        #expect(server.unsupportedFields(for: .opencode).isEmpty)
        // Codex cannot send headers at all.
        #expect(server.unsupportedFields(for: .codex).map(\.field) == ["headers"])
    }

    @Test func aBearerTokenVariableIsCodexOnly() {
        var server = McpServer(name: "remote", transport: .http(url: "https://x", headers: [:]))
        server.bearerTokenEnvVar = "API_TOKEN"
        #expect(server.unsupportedFields(for: .codex).isEmpty)
        for agent in [McpAgent.claude, .cursor, .opencode, .antigravity] {
            #expect(server.unsupportedFields(for: agent).map(\.field) == ["bearerTokenEnvVar"])
        }
    }

    @Test func unsupportedFieldsKeepEnvThenHeadersSortedByName() {
        let server = McpServer(
            name: "x",
            transport: .http(url: "https://x", headers: ["B": .passthrough("B"), "A": .passthrough("A")]),
            env: ["Z": .passthrough("Z"), "M": .passthrough("M"), "L": .literal("l")],
            timeouts: McpTimeouts(toolSeconds: 5)
        )
        #expect(server.unsupportedFields(for: .antigravity).map(\.field)
            == ["env.M", "env.Z", "headers.A", "headers.B", "timeouts"])
    }

    @Test func capabilitiesMatchUpstream() {
        #expect(McpAgent.claude.capability.projectScope)
        #expect(!McpAgent.claude.capability.enabledFlag)
        #expect(McpAgent.codex.capability.enabledFlag && McpAgent.codex.capability.envPassthrough)
        #expect(McpAgent.codex.capability.timeouts && !McpAgent.codex.capability.headers)
        #expect(McpAgent.opencode.capability.enabledFlag && McpAgent.opencode.capability.envPassthrough)
        #expect(!McpAgent.antigravity.capability.projectScope)
        #expect(McpAgent.allCases.allSatisfy { $0.capability.remote && $0.capability.agent == $0 })
    }

    @Test func launchServersConvertBothWays() {
        let launch = McpLaunchServer(name: "graphify", command: "graphify", arguments: ["/repo", "--mcp"], environment: ["K": "V"])
        let server = McpServer(launch: launch)
        #expect(server.transport == .stdio(command: "graphify", arguments: ["/repo", "--mcp"], cwd: nil))
        #expect(server.env == ["K": .literal("V")])
        #expect(server.enabled)
        #expect(server.launchServer == launch)

        var passthrough = server
        passthrough.env["P"] = .passthrough("P")
        #expect(passthrough.launchServer == nil)
        #expect(McpServer(name: "r", transport: .http(url: "https://x", headers: [:])).launchServer == nil)
        #expect(McpServer(name: "c", transport: .stdio(command: "x", arguments: [], cwd: "/tmp")).launchServer == nil)
    }
}
