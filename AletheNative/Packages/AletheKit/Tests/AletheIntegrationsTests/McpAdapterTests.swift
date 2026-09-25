import AletheFoundation
import Foundation
import Testing
@testable import AletheIntegrations

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MCP"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func byName(_ servers: [McpServer], _ name: String) throws -> McpServer {
    try #require(servers.first { $0.name == name })
}

private let userSource = McpSource(url: URL(filePath: "/x/config"), kind: .user)

private func probe(_ name: String) -> McpServer {
    McpServer(name: name, transport: .stdio(command: "node", arguments: ["-e", "0"], cwd: nil))
}

private let claude = ClaudeMcpAdapter()
private let codex = CodexMcpAdapter()
private let cursor = CursorMcpAdapter()
private let opencode = OpenCodeMcpAdapter()
private let antigravity = AntigravityMcpAdapter()

// MARK: - Codex (upstream mcp_agents.rs cases)

@Suite struct CodexMcpAdapterTests {
    @Test func readsEveryTableShape() throws {
        let servers = try codex.parse(try fixture("codex-config.toml"), source: userSource)
        #expect(servers.map(\.name) == ["discord", "figma", "swarm"])

        let discord = try byName(servers, "discord")
        #expect(discord.transport == .stdio(command: "npx", arguments: ["-y", "@quadslab.io/discord-mcp"], cwd: nil))
        #expect(discord.env["DISCORD_TOKEN"]?.literal == "a-live-secret-token-value")

        let figma = try byName(servers, "figma")
        #expect(figma.transport == .http(url: "https://mcp.figma.com/mcp", headers: [:]))
    }

    @Test func keepsAKeyThatIsBothLiteralAndPassthrough() throws {
        let swarm = try byName(try codex.parse(try fixture("codex-config.toml"), source: userSource), "swarm")
        #expect(swarm.env["QUADRANT"] == McpEnvEntry(literal: "1", passthroughFrom: "QUADRANT"))
        #expect(swarm.env["SESSION"] == .passthrough("SESSION"))
        #expect(swarm.env["NODE_ENV"] == .literal("production"))
    }

    @Test func readsBothIntegerAndFloatTimeouts() throws {
        let swarm = try byName(try codex.parse(try fixture("codex-config.toml"), source: userSource), "swarm")
        #expect(swarm.timeouts == McpTimeouts(startupSeconds: 30, toolSeconds: 120))
        #expect(CodexMcpAdapter.seconds(.integer(-1)) == nil)
        #expect(CodexMcpAdapter.seconds(.float(-1)) == nil)
        #expect(CodexMcpAdapter.seconds(.float(.infinity)) == nil)
        #expect(CodexMcpAdapter.seconds(.float(1.6)) == 2)
        #expect(CodexMcpAdapter.seconds(.string("5")) == nil)
    }

    @Test func withoutServersIsEmptyNotAnError() throws {
        #expect(try codex.parse("model = \"x\"\n", source: userSource).isEmpty)
        #expect(try codex.parse("", source: userSource).isEmpty)
        #expect(try codex.parse("  \n", source: userSource).isEmpty)
    }

    @Test func parseErrorCarriesNoFileContent() {
        do {
            _ = try codex.parse("[mcp_servers.broken\ntoken = \"secret-value\"", source: userSource)
            Issue.record("expected an error")
        } catch {
            guard case .unparsableTOML = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(error.description.hasPrefix("unparsable:toml"))
            #expect(!error.description.contains("secret-value"))
        }
    }

    @Test func removeTakesTheEnvSubtableWithIt() throws {
        let next = try codex.remove(try fixture("codex-config.toml"), source: userSource, name: "discord")
        #expect(!next.contains("[mcp_servers.discord]"))
        #expect(!next.contains("[mcp_servers.discord.env]"))
        #expect(!next.contains("a-live-secret-token-value"))
        #expect(next.contains("[mcp_servers.figma]"))
        #expect(next.contains("[[hooks.PreToolUse]]"))
        #expect(next.contains("[projects.\"D:\\\\repo\\\\one\"]"))
        #expect(try codex.parse(next, source: userSource).map(\.name) == ["figma", "swarm"])
    }

    @Test func upsertLeavesEveryOtherTableUntouched() throws {
        let original = try fixture("codex-config.toml")
        let next = try codex.upsert(original, source: userSource, server: probe("alethe-probe"))
        let before = try codex.parse(original, source: userSource)
        let after = try codex.parse(next, source: userSource)

        #expect(after.count == before.count + 1)
        for server in before {
            #expect(try byName(after, server.name) == server)
        }
        #expect(next.contains("[[hooks.PreToolUse]]"))
        #expect(next.contains("model = \"gpt-5.6-sol\""))
        #expect(try byName(after, "alethe-probe") == probe("alethe-probe"))
    }

    @Test func upsertRoundTripsTimeoutsAndPassthrough() throws {
        var server = probe("alethe-probe")
        server.timeouts = McpTimeouts(startupSeconds: 12, toolSeconds: 90)
        server.env["MODE"] = .literal("prod")
        server.env["FOO"] = .passthrough("FOO")

        let next = try codex.upsert(try fixture("codex-config.toml"), source: userSource, server: server)
        let written = try byName(try codex.parse(next, source: userSource), "alethe-probe")
        #expect(written == server)
        #expect(next.contains("env = { MODE = \"prod\" }"))
        #expect(next.contains("env_vars = [\"FOO\"]"))
    }

    @Test func upsertKeepsAHandWrittenEnvSectionAsASection() throws {
        var server = probe("discord")
        server.transport = .stdio(command: "npx", arguments: ["-y", "@quadslab.io/discord-mcp"], cwd: nil)
        server.env["DISCORD_GUILD_ID"] = .literal("456")

        let next = try codex.upsert(try fixture("codex-config.toml"), source: userSource, server: server)
        #expect(next.contains("[mcp_servers.discord.env]"))
        #expect(!next.contains("a-live-secret-token-value"))
        #expect(try byName(try codex.parse(next, source: userSource), "discord") == server)
    }

    @Test func upsertKeepsKeysAletheDoesNotOwn() throws {
        let raw = "[mcp_servers.a]\ncommand = \"old\"\nstartup_timeout_ms = 500 # custom\n"
        let next = try codex.upsert(raw, source: userSource, server: probe("a"))
        #expect(next.contains("startup_timeout_ms = 500 # custom"))
        #expect(!next.contains("\"old\""))
    }

    @Test func upsertWritesRemoteDisabledAndBearer() throws {
        var server = McpServer(name: "remote", transport: .sse(url: "https://r.example/mcp", headers: [:]))
        server.enabled = false
        server.bearerTokenEnvVar = "R_TOKEN"
        let next = try codex.upsert("", source: userSource, server: server)
        let written = try byName(try codex.parse(next, source: userSource), "remote")
        #expect(written.transport == .http(url: "https://r.example/mcp", headers: [:]))
        #expect(!written.enabled)
        #expect(written.bearerTokenEnvVar == "R_TOKEN")

        server.enabled = true
        let enabled = try codex.upsert(next, source: userSource, server: server)
        #expect(!enabled.contains("enabled"))
    }

    @Test func setEnabledFlipsOnlyThatServer() throws {
        let next = try codex.setEnabled(try fixture("codex-config.toml"), source: userSource, name: "figma", enabled: false)
        let parsed = try codex.parse(next, source: userSource)
        #expect(try !byName(parsed, "figma").enabled)
        #expect(try byName(parsed, "discord").enabled)
    }

    @Test func mutationsReportNotFoundForAnUnknownServer() throws {
        let raw = try fixture("codex-config.toml")
        #expect(throws: McpConfigError.notFound) { try codex.remove(raw, source: userSource, name: "ghost") }
        #expect(throws: McpConfigError.notFound) { try codex.setEnabled(raw, source: userSource, name: "ghost", enabled: false) }
        #expect(throws: McpConfigError.notFound) { try codex.remove("", source: userSource, name: "ghost") }
    }

    @Test func upsertKeepsAnExplicitServersHeaderAndItsComment() throws {
        let raw = "# my servers\n[mcp_servers]\n\n[mcp_servers.figma]\nurl = \"https://x\"\n"
        let next = try codex.upsert(raw, source: userSource, server: probe("alethe-probe"))
        #expect(next.contains("# my servers"))
        #expect(next.contains("[mcp_servers]"))
        #expect(try codex.parse(next, source: userSource).count == 2)
    }

    @Test func anEditedAndEditedBackFileIsUnchanged() throws {
        let original = try fixture("codex-config.toml")
        let added = try codex.upsert(original, source: userSource, server: probe("alethe-probe"))
        #expect(try codex.remove(added, source: userSource, name: "alethe-probe") == original)
    }
}

// MARK: - Claude Code

private let claudeInline = """
{
  "numStartups": 1871,
  "installMethod": "global",
  "mcpServers": {
    "figma": { "type": "http", "url": "https://mcp.figma.com/mcp" }
  },
  "projects": { "D:\\\\repo": { "allowedTools": [] } }
}
"""

@Suite struct ClaudeMcpAdapterTests {
    @Test func readsStdioAndHTTPEntries() throws {
        let raw = """
        {
          "numStartups": 12,
          "mcpServers": {
            "higgsfield": { "type": "http", "url": "https://mcp.higgsfield.ai/mcp" },
            "swarm": { "type": "stdio", "command": "node", "args": ["a.js"], "env": { "K": "V" } }
          }
        }
        """
        let servers = try claude.parse(raw, source: userSource)
        #expect(servers.count == 2)
        let swarm = try byName(servers, "swarm")
        #expect(swarm.env["K"]?.literal == "V")
        #expect(swarm.enabled)
        #expect(try byName(servers, "higgsfield").transport == .http(url: "https://mcp.higgsfield.ai/mcp", headers: [:]))
    }

    @Test func doesNotTreatEnvInterpolationAsPassthrough() throws {
        let raw = #"{"mcpServers":{"a":{"command":"node","env":{"K":"{env:K}"}}}}"#
        let entry = try #require(try claude.parse(raw, source: userSource).first?.env["K"])
        #expect(entry == .literal("{env:K}"))
    }

    @Test func honoursAnExplicitDisabledFlag() throws {
        let raw = #"{"mcpServers":{"a":{"command":"node","disabled":true}}}"#
        #expect(try claude.parse(raw, source: userSource).first?.enabled == false)
    }

    @Test func readsTheFixtureWithSSEAndMaskedHeaders() throws {
        let servers = try claude.parse(try fixture("claude.json"), source: userSource)
        #expect(servers.map(\.name) == ["figma", "notes"])
        let notes = try byName(servers, "notes")
        #expect(notes.transport == .sse(url: "https://notes.example/sse", headers: ["Authorization": .literal("Bearer a-live-header-secret")]))
        #expect(!String(describing: notes.view).contains("a-live-header-secret"))
    }

    @Test func upsertKeepsTopLevelKeyOrderAndUnrelatedKeys() throws {
        let next = try claude.upsert(claudeInline, source: userSource, server: probe("alethe-probe"))
        let numStartups = try #require(next.range(of: "numStartups")).lowerBound
        let install = try #require(next.range(of: "installMethod")).lowerBound
        let projects = try #require(next.range(of: "\"projects\"")).lowerBound
        #expect(numStartups < install && install < projects)

        let parsed = try claude.parse(next, source: userSource)
        #expect(parsed.count == 2)
        #expect(try byName(parsed, "figma").transport.isRemote)
        #expect(try byName(parsed, "alethe-probe") == probe("alethe-probe"))
    }

    @Test func upsertPreservesUnknownKeysOnTheEntry() throws {
        let raw = #"{"mcpServers":{"a":{"command":"old","trustLevel":"always"}}}"#
        let next = try claude.upsert(raw, source: userSource, server: probe("a"))
        #expect(next.contains("trustLevel"))
        #expect(!next.contains("\"old\""))
    }

    @Test func removingOneServerDoesNotMoveItsSiblings() throws {
        let raw = #"{"mcpServers":{"a":{"command":"x"},"b":{"command":"x"},"c":{"command":"x"},"d":{"command":"x"}}}"#
        let next = try claude.remove(raw, source: userSource, name: "b")
        let positions = try ["\"a\"", "\"c\"", "\"d\""].map { try #require(next.range(of: $0)).lowerBound }
        #expect(positions[0] < positions[1] && positions[1] < positions[2])
        #expect(!next.contains("\"b\""))
    }

    @Test func upsertKeepsTheRelativeOrderOfHandAddedKeys() throws {
        let raw = #"{"mcpServers":{"a":{"command":"old","first":1,"second":2,"third":3}}}"#
        let next = try claude.upsert(raw, source: userSource, server: probe("a"))
        let first = try #require(next.range(of: "\"first\"")).lowerBound
        let second = try #require(next.range(of: "\"second\"")).lowerBound
        let third = try #require(next.range(of: "\"third\"")).lowerBound
        #expect(first < second && second < third)
    }

    @Test func upsertWritesUpstreamsEntryShape() throws {
        var server = McpServer(name: "s", transport: .stdio(command: "node", arguments: ["a.js"], cwd: "/w"))
        server.env = ["B": .literal("2"), "A": .literal("1"), "P": .passthrough("P")]
        server.enabled = false
        let next = try claude.upsert("", source: userSource, server: server)
        let entry = try #require(try JSONConfigEditor(parsing: next).value(at: ["mcpServers", "s"])?.objectValue)
        #expect(entry.keys == ["env", "type", "command", "args", "cwd", "disabled"])
        #expect(entry["env"]?.objectValue?.keys == ["A", "B"])
        #expect(entry["type"] == .string("stdio"))

        let remote = McpServer(name: "r", transport: .sse(url: "https://r", headers: ["H": .literal("v")]))
        let remoteEntry = try #require(try JSONConfigEditor(parsing: try claude.upsert("", source: userSource, server: remote))
            .value(at: ["mcpServers", "r"])?.objectValue)
        #expect(remoteEntry.keys == ["type", "url", "headers"])
        #expect(remoteEntry["type"] == .string("sse"))
    }

    @Test func cannotDisableAServer() {
        #expect(throws: McpConfigError.unsupportedDisable) {
            try claude.setEnabled(claudeInline, source: userSource, name: "figma", enabled: false)
        }
    }

    @Test func upsertCreatesTheRootKeyInAnEmptyFile() throws {
        let next = try claude.upsert("", source: userSource, server: probe("a"))
        #expect(try claude.parse(next, source: userSource).count == 1)
        #expect(next.hasSuffix("}\n"))
    }

    @Test func removeReportsNotFound() throws {
        #expect(throws: McpConfigError.notFound) { try claude.remove(claudeInline, source: userSource, name: "ghost") }
        let next = try claude.remove(claudeInline, source: userSource, name: "figma")
        #expect(try claude.parse(next, source: userSource).isEmpty)
        #expect(next.contains("numStartups"))
    }

    @Test func localServersLiveUnderTheirProjectEntry() throws {
        let raw = try fixture("claude.json")
        let local = McpSource(url: URL(filePath: "/x/.claude.json"), kind: .local, projectKey: "/Users/me/repo")
        let servers = try claude.parse(raw, source: local)
        #expect(servers.map(\.name) == ["swarm"])

        // The existing entry is found despite its trailing slash; unknown keys survive.
        var updated = probe("swarm")
        updated.env["K"] = .literal("W")
        let next = try claude.upsert(raw, source: local, server: updated)
        let editor = try JSONConfigEditor(parsing: next)
        #expect(editor.value(at: ["projects"])?.objectValue?.keys == ["/Users/me/repo/", "/Users/me/other"])
        #expect(editor.value(at: ["projects", "/Users/me/repo/", "mcpServers", "swarm", "trustLevel"]) == .string("always"))
        #expect(try claude.parse(next, source: local) == [updated])
        #expect(try claude.parse(next, source: userSource).map(\.name) == ["figma", "notes"])

        let removed = try claude.remove(next, source: local, name: "swarm")
        #expect(try claude.parse(removed, source: local).isEmpty)
        #expect(throws: McpConfigError.notFound) {
            try claude.remove(raw, source: McpSource(url: local.url, kind: .local, projectKey: "/Users/me/other"), name: "swarm")
        }
    }

    @Test func aMissingProjectEntryIsCreatedOnUpsert() throws {
        let local = McpSource(url: URL(filePath: "/x/.claude.json"), kind: .local, projectKey: "/Users/me/new")
        #expect(try claude.parse(try fixture("claude.json"), source: local).isEmpty)
        let next = try claude.upsert(try fixture("claude.json"), source: local, server: probe("p"))
        #expect(try JSONConfigEditor(parsing: next).value(at: ["projects"])?.objectValue?.keys.last == "/Users/me/new")
        #expect(try claude.parse(next, source: local).map(\.name) == ["p"])
    }

    @Test func aNonObjectContainerIsNeverReplaced() throws {
        #expect(throws: McpConfigError.layoutConflict(path: ["mcpServers"])) {
            try claude.upsert(#"{"mcpServers": []}"#, source: userSource, server: probe("a"))
        }
        #expect(throws: McpConfigError.rootNotAnObject) {
            try claude.upsert("[1]", source: userSource, server: probe("a"))
        }
        #expect(try claude.parse("[1]", source: userSource).isEmpty)
    }

    @Test func jsonErrorsCarryAPositionAndNoContent() {
        do {
            _ = try claude.parse("{\n  \"token\": \"secret-json-value\" oops }", source: userSource)
            Issue.record("expected an error")
        } catch {
            guard case .unparsableJSON(let line, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(line == 2)
            #expect(!error.description.contains("secret-json-value"))
        }
    }

    @Test func projectKeysUseForwardSlashes() {
        #expect(ClaudeMcpAdapter.projectKey(forPath: #"D:\kauam\repo"#) == "D:/kauam/repo")
        #expect(ClaudeMcpAdapter.projectKey(for: URL(filePath: "/Users/me/repo/", directoryHint: .isDirectory)) == "/Users/me/repo")
        #expect(ClaudeMcpAdapter.projectKey(forPath: "/") == "/")
    }
}

// MARK: - OpenCode

private let opencodeInline = """
{
  "$schema": "https://opencode.ai/config.json",
  "model": "provider/model",
  "mcp": {
    "swarm": { "type": "local", "command": ["node", "a.js"], "enabled": true }
  }
}
"""

@Suite struct OpenCodeMcpAdapterTests {
    @Test func splitsTheCommandArrayAndReadsPassthrough() throws {
        let raw = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "swarm": {
              "type": "local",
              "command": ["node", "C:/x/server.js"],
              "enabled": false,
              "environment": { "QUADRANT": "{env:QUADRANT}", "MODE": "prod" }
            }
          }
        }
        """
        let swarm = try #require(try opencode.parse(raw, source: userSource).first)
        #expect(swarm.transport == .stdio(command: "node", arguments: ["C:/x/server.js"], cwd: nil))
        #expect(!swarm.enabled)
        #expect(swarm.env["QUADRANT"] == .passthrough("QUADRANT"))
        #expect(swarm.env["MODE"] == .literal("prod"))
    }

    @Test func configWithoutMcpIsEmpty() throws {
        #expect(try opencode.parse(#"{"model":"a/b"}"#, source: userSource).isEmpty)
        #expect(try opencode.parse(try fixture("opencode.json"), source: userSource).map(\.name) == ["swarm"])
    }

    @Test func upsertWritesOneCommandArrayAndInterpolatedEnv() throws {
        var server = probe("alethe-probe")
        server.env["FOO"] = .passthrough("FOO")
        let next = try opencode.upsert(opencodeInline, source: userSource, server: server)
        #expect(next.contains("\"$schema\""))
        #expect(next.contains("\"model\""))
        #expect(next.contains("{env:FOO}"))

        let written = try byName(try opencode.parse(next, source: userSource), "alethe-probe")
        #expect(written == server)
        let entry = try #require(try JSONConfigEditor(parsing: next).value(at: ["mcp", "alethe-probe"])?.objectValue)
        #expect(entry.keys == ["environment", "type", "command", "enabled"])
    }

    @Test func remoteServersAreWrittenAsRemote() throws {
        let server = McpServer(name: "r", transport: .http(url: "https://r", headers: ["Authorization": .passthrough("TOKEN")]))
        let next = try opencode.upsert("", source: userSource, server: server)
        #expect(next.contains("\"type\": \"remote\""))
        #expect(next.contains("{env:TOKEN}"))
        #expect(try opencode.parse(next, source: userSource) == [server])
    }

    @Test func removeKeepsEverySiblingKey() throws {
        let next = try opencode.remove(opencodeInline, source: userSource, name: "swarm")
        #expect(next.contains("\"$schema\""))
        #expect(next.contains("\"model\""))
        #expect(try opencode.parse(next, source: userSource).isEmpty)
    }

    @Test func setEnabledWritesTheFlag() throws {
        let next = try opencode.setEnabled(opencodeInline, source: userSource, name: "swarm", enabled: false)
        #expect(try opencode.parse(next, source: userSource).first?.enabled == false)
        #expect(throws: McpConfigError.notFound) {
            try opencode.setEnabled(opencodeInline, source: userSource, name: "ghost", enabled: false)
        }
    }

    @Test func jsoncIsReadButNeverWritten() throws {
        let source = McpSource(url: URL(filePath: "/x/opencode.jsonc"), kind: .project)
        let servers = try opencode.parse(try fixture("opencode.jsonc"), source: source)
        #expect(servers.map(\.name) == ["local-one", "remote-one"])
        #expect(try byName(servers, "remote-one").transport
            == .http(url: "https://mcp.example/mcp", headers: ["Authorization": .passthrough("REMOTE_TOKEN")]))
        #expect(try byName(servers, "local-one").env == ["MODE": .literal("prod")])

        let raw = try fixture("opencode.jsonc")
        #expect(throws: McpConfigError.jsoncUnsupported) { try opencode.upsert(raw, source: source, server: probe("a")) }
        #expect(throws: McpConfigError.jsoncUnsupported) { try opencode.remove(raw, source: source, name: "local-one") }
        #expect(throws: McpConfigError.jsoncUnsupported) {
            try opencode.setEnabled(raw, source: source, name: "local-one", enabled: false)
        }
    }
}

// MARK: - Cursor and Antigravity

@Suite struct ClaudeShapedAdapterTests {
    @Test func cursorReadsTheClaudeShapeAndKeepsAProjectFile() throws {
        let raw = #"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/sse"}}}"#
        #expect(try cursor.parse(raw, source: userSource).count == 1)

        let servers = try cursor.parse(try fixture("cursor-mcp.json"), source: userSource)
        #expect(servers.map(\.name) == ["figma", "github"])
        #expect(!String(describing: servers.map(\.view)).contains("ghp-a-live-secret-token"))

        let sources = cursor.configSources(scope: .project, repository: URL(filePath: "/repo", directoryHint: .isDirectory),
                                           home: McpHome(home: URL(filePath: "/home")))
        #expect(sources.map(\.url.path) == ["/repo/.cursor/mcp.json"])
        #expect(throws: McpConfigError.unsupportedDisable) {
            try cursor.setEnabled(raw, source: userSource, name: "figma", enabled: false)
        }
    }

    @Test func antigravitySharesTheClaudeShape() throws {
        let raw = #"{"mcpServers":{"swarm":{"type":"stdio","command":"node","args":["a.js"]}}}"#
        #expect(try antigravity.parse(raw, source: userSource).count == 1)
        let servers = try antigravity.parse(try fixture("antigravity-mcp_config.json"), source: userSource)
        #expect(servers.map(\.name) == ["codeagentswarm-tasks", "figma"])
    }

    @Test func antigravityHasNoProjectScope() {
        #expect(antigravity.configSources(scope: .project, repository: URL(filePath: "/repo"), home: McpHome(home: URL(filePath: "/home"))).isEmpty)
    }

    @Test func antigravityWritesTheClaudeShapeAndKeepsUnknownKeys() throws {
        let next = try antigravity.upsert(#"{"mcpServers":{}}"#, source: userSource, server: probe("a"))
        #expect(try antigravity.parse(next, source: userSource).count == 1)

        let raw = try fixture("antigravity-mcp_config.json")
        let figma = McpServer(name: "figma", transport: .http(url: "https://mcp.figma.com/v2", headers: [:]))
        let updated = try antigravity.upsert(raw, source: userSource, server: figma)
        #expect(updated.contains("\"serverUrl\": \"ignored\""))
        #expect(try byName(try antigravity.parse(updated, source: userSource), "figma") == figma)
    }

    @Test func antigravityImportsMatchByNamePrefix() throws {
        let imports = AntigravityMcpAdapter.importNames(manifest: try fixture("antigravity-import_manifest.json"))
        #expect(imports == ["codeagentswarm"])
        #expect(AntigravityMcpAdapter.importOwner(of: "CodeAgentSwarm-tasks", imports: imports) == "codeagentswarm")
        #expect(AntigravityMcpAdapter.importOwner(of: "figma", imports: imports) == nil)
        #expect(AntigravityMcpAdapter.importNames(manifest: "not json").isEmpty)
        #expect(AntigravityMcpAdapter.importManifestURL(home: McpHome(home: URL(filePath: "/home"))).path
            == "/home/.gemini/config/import_manifest.json")
    }
}

// MARK: - Config sources

@Suite struct McpConfigSourceTests {
    private let home = McpHome(home: URL(filePath: "/home/me", directoryHint: .isDirectory))
    private let repo = URL(filePath: "/work/repo", directoryHint: .isDirectory)

    @Test func globalPathsFollowEachAgentConvention() {
        func paths(_ agent: McpAgent) -> [String] {
            McpAdapters.adapter(for: agent).configSources(scope: .global, repository: nil, home: home).map(\.url.path)
        }
        #expect(paths(.claude) == ["/home/me/.claude.json"])
        #expect(paths(.codex) == ["/home/me/.codex/config.toml"])
        #expect(paths(.cursor) == ["/home/me/.cursor/mcp.json"])
        #expect(paths(.opencode) == ["/home/me/.config/opencode/opencode.json"])
        #expect(paths(.antigravity) == ["/home/me/.gemini/config/mcp_config.json"])
        for agent in McpAgent.allCases {
            #expect(McpAdapters.adapter(for: agent).agent == agent)
            #expect(McpAdapters.adapter(for: agent).configSources(scope: .global, repository: nil, home: home).allSatisfy { $0.kind == .user })
        }
    }

    @Test func projectPathsFollowEachAgentConvention() {
        let claudeSources = claude.configSources(scope: .project, repository: repo, home: home)
        #expect(claudeSources.count == 2)
        #expect(claudeSources[0].url.path == "/home/me/.claude.json")
        #expect(claudeSources[0].kind == .local)
        #expect(claudeSources[0].projectKey == "/work/repo")
        #expect(claudeSources[1].url.path == "/work/repo/.mcp.json")
        #expect(claudeSources[1].kind == .project)

        #expect(codex.configSources(scope: .project, repository: repo, home: home).map(\.url.path) == ["/work/repo/.codex/config.toml"])
        #expect(opencode.configSources(scope: .project, repository: repo, home: home).map(\.url.path) == ["/work/repo/opencode.json"])
        for agent in McpAgent.allCases {
            #expect(McpAdapters.adapter(for: agent).configSources(scope: .project, repository: nil, home: home).isEmpty)
        }
    }

    @Test func homeHonoursTheOverrideAndXDG() {
        let overridden = McpHome.current(environment: ["ALETHE_MCP_HOME": "/scratch", "HOME": "/home/me", "XDG_CONFIG_HOME": "/xdg"])
        #expect(overridden.home.path == "/scratch")
        #expect(overridden.xdgConfigHome == nil)

        let xdg = McpHome.current(environment: ["HOME": "/home/me", "XDG_CONFIG_HOME": "/xdg"])
        #expect(opencode.configSources(scope: .global, repository: nil, home: xdg).map(\.url.path) == ["/xdg/opencode/opencode.json"])

        let plain = McpHome.current(environment: ["HOME": "/home/me", "ALETHE_MCP_HOME": "", "XDG_CONFIG_HOME": ""])
        #expect(plain.home.path == "/home/me")
        #expect(plain.xdgConfigHome == nil)
    }

    @Test func openCodeFallsBackToJSONCOnlyWhenItIsTheOnlyFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "alethe-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func picked() -> String? {
            opencode.configSources(scope: .project, repository: folder, home: home).first?.url.lastPathComponent
        }
        #expect(picked() == "opencode.json")
        try Data("{}".utf8).write(to: folder.appending(path: "opencode.jsonc"))
        #expect(picked() == "opencode.jsonc")
        try Data("{}".utf8).write(to: folder.appending(path: "opencode.json"))
        #expect(picked() == "opencode.json")
    }
}
