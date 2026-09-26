import Foundation
import Testing
@testable import AletheAgents

/// Per-launch MCP wiring (P5-4).
@Suite struct McpLaunchTests {
    static let launcher = AgentLauncher(launchers: LauncherCache(stillExists: { _ in true }),
                                        overrides: ["claude": "/bin/echo", "codex": "/bin/echo", "opencode": "/bin/echo"])
    static let graphify = McpLaunchServer(name: "graphify", command: "/usr/local/bin/graphify", arguments: ["/repo", "--mcp"])
    static let memory = McpLaunchServer(name: "ai-memory", command: "ai-memory", arguments: ["mcp"], environment: ["TOKEN": "s3"])

    static func command(_ request: AgentLaunchRequest) throws -> AgentCommand {
        try launcher.command(for: request, makeSessionID: { "new" })
    }

    @Test func claudeTakesTheFileAfterSessionFlagsAndBeforeSettings() throws {
        let resumed = try Self.command(AgentLaunchRequest(kind: .claude, extraArguments: ["--verbose"], sessionID: "s1",
                                                          hooks: .init(claudeSettingsPath: "/tmp/h.json"),
                                                          mcpServers: [Self.graphify], mcpConfigPath: "/tmp/m.json"))
        #expect(resumed.shellCommand?.hasSuffix("'--resume' 's1' '--mcp-config=/tmp/m.json' '--settings' '/tmp/h.json' '--verbose'") == true)
        let fresh = try Self.command(AgentLaunchRequest(kind: .claude, mcpServers: [Self.graphify], mcpConfigPath: "/tmp/m.json"))
        #expect(fresh.shellCommand?.hasSuffix("'--session-id' 'new' '--mcp-config=/tmp/m.json'") == true)
    }

    @Test func claudeWithoutServersOrFileGetsNoFlag() throws {
        let noServers = try Self.command(AgentLaunchRequest(kind: .claude, mcpConfigPath: "/tmp/m.json"))
        #expect(noServers.shellCommand?.contains("--mcp-config") == false)
        let noFile = try Self.command(AgentLaunchRequest(kind: .claude, mcpServers: [Self.graphify]))
        #expect(noFile.shellCommand?.contains("--mcp-config") == false)
    }

    @Test func pathsWithQuotesAndSpacesStayOneArgument() throws {
        let command = try Self.command(AgentLaunchRequest(kind: .claude, mcpServers: [Self.graphify],
                                                          mcpConfigPath: "/tmp/it's here/m.json"))
        #expect(command.shellCommand?.contains(#"'--mcp-config=/tmp/it'\''s here/m.json'"#) == true)
    }

    @Test func codexOverridesGoAfterHooksAndBeforeResume() throws {
        let command = try Self.command(AgentLaunchRequest(kind: .codex, sessionID: "c1",
                                                          hooks: .init(codexArguments: ["-c", "notify=[]"]),
                                                          mcpServers: [Self.graphify]))
        #expect(command.shellCommand?.hasSuffix(
            #"'-c' 'notify=[]' '-c' 'mcp_servers.graphify.command="/usr/local/bin/graphify"' '-c' 'mcp_servers.graphify.args=["/repo","--mcp"]' 'resume' 'c1'"#) == true)
        #expect(command.environment["OPENCODE_CONFIG"] == nil)
    }

    @Test func codexArgumentsQuoteTomlAndSanitizeNames() {
        let server = McpLaunchServer(name: "my.server", command: #"C:\bin\"x""#, arguments: ["a\nb"],
                                     environment: ["B": "2", "A": "1"])
        #expect(McpLaunchConfig.codexArguments([server, Self.graphify, Self.graphify]) == [
            "-c", #"mcp_servers.my_server.command="C:\\bin\\\"x\"""#,
            "-c", #"mcp_servers.my_server.args=["a\nb"]"#,
            "-c", #"mcp_servers.my_server.env={"A"="1","B"="2"}"#,
            "-c", #"mcp_servers.graphify.command="/usr/local/bin/graphify""#,
            "-c", #"mcp_servers.graphify.args=["/repo","--mcp"]"#,
        ])
        #expect(McpLaunchConfig.tomlString("\u{1}") == #""\u0001""#)
    }

    @Test func opencodeGetsTheFileThroughItsEnvironment() throws {
        let command = try Self.command(AgentLaunchRequest(kind: .opencode, sessionID: "o1",
                                                          mcpServers: [Self.memory], mcpConfigPath: "/tmp/o.json"))
        #expect(command.environment["OPENCODE_CONFIG"] == .some("/tmp/o.json"))
        #expect(command.shellCommand?.hasSuffix("'--session' 'o1'") == true)
        let without = try Self.command(AgentLaunchRequest(kind: .opencode, mcpConfigPath: "/tmp/o.json"))
        #expect(without.environment["OPENCODE_CONFIG"] == nil)
    }

    @Test func claudeConfigShape() throws {
        let data = McpLaunchConfig.claudeConfig([Self.graphify, Self.memory, McpLaunchServer(name: "graphify", command: "other")])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: [String: Any]])
        #expect(Set(servers.keys) == ["graphify", "ai-memory"])
        #expect(servers["graphify"]?["command"] as? String == "/usr/local/bin/graphify", "first of a name wins")
        #expect(servers["graphify"]?["args"] as? [String] == ["/repo", "--mcp"])
        #expect(servers["graphify"]?["env"] == nil)
        #expect(servers["ai-memory"]?["env"] as? [String: String] == ["TOKEN": "s3"])
    }

    @Test func opencodeConfigShape() throws {
        let data = McpLaunchConfig.opencodeConfig([Self.graphify, Self.memory])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["$schema"] as? String == "https://opencode.ai/config.json")
        let servers = try #require(object["mcp"] as? [String: [String: Any]])
        #expect(servers["graphify"]?["type"] as? String == "local")
        #expect(servers["graphify"]?["command"] as? [String] == ["/usr/local/bin/graphify", "/repo", "--mcp"])
        #expect(servers["graphify"]?["enabled"] as? Bool == true)
        #expect(servers["ai-memory"]?["environment"] as? [String: String] == ["TOKEN": "s3"])
    }

    @Test func onlyWiredAgentsTakeServers() throws {
        #expect(McpLaunchConfig.supports(.claude) && McpLaunchConfig.supports(.codex) && McpLaunchConfig.supports(.opencode))
        #expect(!McpLaunchConfig.supports(.cursor) && !McpLaunchConfig.supports(.kiro))
        #expect(McpLaunchConfig.needsFile(.claude) && McpLaunchConfig.needsFile(.opencode) && !McpLaunchConfig.needsFile(.codex))
        #expect(McpLaunchConfig.file(for: .codex, servers: [Self.graphify]) == nil)
        let launcher = AgentLauncher(launchers: LauncherCache(stillExists: { _ in true }), overrides: ["kiro": "/bin/echo"])
        let kiro = try launcher.command(for: AgentLaunchRequest(kind: .kiro, mcpServers: [Self.graphify], mcpConfigPath: "/tmp/m.json"))
        #expect(kiro.shellCommand?.hasSuffix("'/bin/echo' 'chat'") == true)
    }

    // MARK: HTTP servers (P6-9)

    static let orchestrator = McpLaunchServer.http(name: "alethe", url: "http://127.0.0.1:4000/mcp",
                                                   headers: ["X-Alethe-Token": "tok", "X-Alethe-Planner": "tab1"])

    @Test func claudeConfigWritesTheHttpForm() throws {
        let data = McpLaunchConfig.claudeConfig([Self.graphify, Self.orchestrator])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let alethe = try #require(servers["alethe"] as? [String: Any])
        #expect(alethe["type"] as? String == "http")
        #expect(alethe["url"] as? String == "http://127.0.0.1:4000/mcp")
        #expect(alethe["headers"] as? [String: String] == ["X-Alethe-Token": "tok", "X-Alethe-Planner": "tab1"])
        #expect(alethe["command"] == nil && alethe["args"] == nil)
        #expect((servers["graphify"] as? [String: Any])?["command"] as? String == "/usr/local/bin/graphify")
    }

    @Test func opencodeConfigWritesARemoteServer() throws {
        let data = McpLaunchConfig.opencodeConfig([Self.orchestrator])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let alethe = try #require((root["mcp"] as? [String: Any])?["alethe"] as? [String: Any])
        #expect(alethe["type"] as? String == "remote")
        #expect(alethe["url"] as? String == "http://127.0.0.1:4000/mcp")
        #expect(alethe["enabled"] as? Bool == true)
    }

    @Test func httpServersNeverReachCodexArguments() throws {
        #expect(McpLaunchConfig.codexArguments([Self.orchestrator]).isEmpty)
        let command = try Self.command(AgentLaunchRequest(kind: .codex, mcpServers: [Self.orchestrator, Self.graphify]))
        #expect(command.shellCommand?.contains("tok") == false)
        #expect(command.shellCommand?.contains("mcp_servers.graphify.command") == true)
    }

    @Test func httpServerIsMarkedAndDeduplicatedByName() {
        #expect(Self.orchestrator.isHTTP && !Self.graphify.isHTTP)
        let stdio = McpLaunchServer(name: "alethe", command: "x")
        #expect(McpLaunchServer.deduplicated([Self.orchestrator, stdio]) == [Self.orchestrator])
    }
}
