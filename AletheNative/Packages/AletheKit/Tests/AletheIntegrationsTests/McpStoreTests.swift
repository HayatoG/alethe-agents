import Foundation
import Testing
@testable import AletheIntegrations

// Upstream `mcp_store.rs` cases (golden), run against throwaway homes; never the user's real configs.

private let codexRealShape = #"""
# hand written
model = "gpt-5.6-sol"

[projects."D:\\repo\\one"]
trust_level = "trusted"

[mcp_servers.discord]
command = "npx"
args = ["-y", "@quadslab.io/discord-mcp"]

[mcp_servers.discord.env]
DISCORD_TOKEN = "a-live-secret-token-value"

[[hooks.PreToolUse]]
name = "gate"

"""#

/// The real `~/.claude.json` shape: `claude mcp add` writes to `projects.<cwd>.mcpServers`, not to the
/// top-level `mcpServers`.
private let claudeRealShape = #"""
{
  "numStartups": 1871,
  "mcpServers": {
    "higgsfield": { "type": "http", "url": "https://mcp.higgsfield.ai/mcp" }
  },
  "projects": {
    "D:/kauam/Documents/Github/Verzel/Retaguarda/Ret-Campanhas": {
      "allowedTools": [],
      "mcpServers": {
        "azure-devops": {
          "type": "stdio",
          "command": "npx",
          "args": ["-y", "@azure-devops/mcp", "GrupoAvenida"],
          "env": {}
        }
      },
      "hasTrustDialogAccepted": true
    }
  }
}
"""#

/// A throwaway home, repository and profile.
private struct Sandbox {
    let root: URL
    let store: McpStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AletheMcpStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appending(path: "repo"), withIntermediateDirectories: true)
        store = McpStore(home: McpHome(home: root.appending(path: "home", directoryHint: .isDirectory)),
                         writer: ConfigFileWriter(profileDirectory: root.appending(path: "profile")))
    }

    var repo: URL { root.appending(path: "repo", directoryHint: .isDirectory) }

    func url(_ relative: String) -> URL { root.appending(path: relative) }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let file = url(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
        return file
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: url(relative), encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func probe(_ name: String) -> McpServer {
    McpServer(name: name, transport: .stdio(command: "node", arguments: ["-e", "0"], cwd: nil))
}

private func fileSource(_ url: URL, _ kind: McpSourceKind) -> McpSource {
    McpSource(url: url, kind: kind)
}

private func localSource(_ url: URL, _ key: String) -> McpSource {
    McpSource(url: url, kind: .local, projectKey: key)
}

// MARK: - Golden (upstream mcp_store.rs tests)

@Suite struct McpStoreGoldenTests {
    @Test func claudeLocalScopeReadsServersFromTheProjectsMap() throws {
        let source = localSource(URL(filePath: "/x/.claude.json"), #"D:\kauam\Documents\Github\Verzel\Retaguarda\Ret-Campanhas"#)
        let servers = try ClaudeMcpAdapter().parse(claudeRealShape, source: source)
        #expect(servers.map(\.name) == ["azure-devops"])
    }

    @Test func claudeGlobalScopeIgnoresTheProjectsMap() throws {
        let servers = try ClaudeMcpAdapter().parse(claudeRealShape, source: fileSource(URL(filePath: "/x/.claude.json"), .user))
        #expect(servers.map(\.name) == ["higgsfield"])
    }

    @Test func claudeLocalLookupIsSlashAndCaseInsensitive() throws {
        let source = localSource(URL(filePath: "/x/.claude.json"), #"d:\KAUAM\Documents\Github\Verzel\Retaguarda\Ret-Campanhas\"#)
        #expect(try ClaudeMcpAdapter().parse(claudeRealShape, source: source).count == 1)
    }

    @Test func claudeLocalWriteLandsInTheMatchingProjectEntry() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.claude.json", claudeRealShape)
        let source = localSource(config, #"D:\kauam\Documents\Github\Verzel\Retaguarda\Ret-Campanhas"#)

        _ = try box.store.apply(.upsert(probe("alethe-probe")), agent: .claude, to: source)

        let written = try #require(box.read("home/.claude.json"))
        #expect(written.contains("azure-devops"))
        #expect(written.contains("alethe-probe"))
        #expect(written.contains("hasTrustDialogAccepted"))
        #expect(written.contains("numStartups"))
        #expect(try ClaudeMcpAdapter().parse(written, source: fileSource(config, .user)).map(\.name) == ["higgsfield"])
        #expect(try ClaudeMcpAdapter().parse(written, source: source).count == 2)
    }

    @Test func claudeLocalWriteCreatesTheProjectEntryWhenAbsent() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.claude.json", #"{"numStartups": 3}"#)
        let source = localSource(config, #"D:\some\new\repo"#)

        _ = try box.store.apply(.upsert(probe("alethe-probe")), agent: .claude, to: source)

        let written = try #require(box.read("home/.claude.json"))
        #expect(written.contains(#""D:/some/new/repo""#))
        #expect(written.contains("numStartups"))
        #expect(try ClaudeMcpAdapter().parse(written, source: source).count == 1)
    }

    @Test func claudeProjectScopeExposesBothTheLocalAndTheSharedFile() {
        let box = Sandbox()
        defer { box.cleanUp() }
        let sources = box.store.sources(.claude, .project, box.repo)
        #expect(sources.map(\.kind) == [.local, .project])
        #expect(sources[0].url.lastPathComponent == ".claude.json")
        #expect(sources[1].url.lastPathComponent == ".mcp.json")
    }

    @Test func writingBacksUpAndLeavesTheRestOfTheFileAlone() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.codex/config.toml", codexRealShape)

        let report = try box.store.apply(.upsert(probe("alethe-probe")), agent: .codex, to: fileSource(config, .user))

        #expect(report.changed == ["alethe-probe"])
        let backup = try #require(report.backup)
        #expect(try String(contentsOf: backup.url, encoding: .utf8) == codexRealShape)
        #expect(backup.slot == ConfigBackupSlot(agent: "codex", kind: "user"))
        #expect(backup.url.path.hasPrefix(box.url("profile").path))

        let written = try #require(box.read("home/.codex/config.toml"))
        #expect(written.contains("# hand written"))
        #expect(written.contains(#"[projects."D:\\repo\\one"]"#))
        #expect(written.contains("[[hooks.PreToolUse]]"))
        #expect(written.contains("[mcp_servers.discord.env]"))
        #expect(written.contains("alethe-probe"))
    }

    @Test func removingDropsTheServerAndItsSubtableOnly() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.codex/config.toml", codexRealShape)

        _ = try box.store.apply(.remove(name: "discord"), agent: .codex, to: fileSource(config, .user))

        let written = try #require(box.read("home/.codex/config.toml"))
        #expect(!written.contains("a-live-secret-token-value"))
        #expect(!written.contains("[mcp_servers.discord"))
        #expect(written.contains("[[hooks.PreToolUse]]"))
        #expect(written.contains("trust_level"))
    }

    @Test func anUpsertCreatesAMissingProjectConfig() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.url("repo/.mcp.json")

        let report = try box.store.apply(.upsert(probe("alethe-probe")), agent: .claude, to: fileSource(config, .project))

        #expect(report.backup == nil)
        let written = try #require(box.read("repo/.mcp.json"))
        #expect(written.contains(#""mcpServers""#))
        #expect(written.contains("alethe-probe"))
    }

    @Test func aFieldTheAgentCannotExpressBlocksTheWrite() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("repo/.mcp.json", "{}")
        var server = probe("alethe-probe")
        server.env["TOKEN"] = .passthrough("TOKEN")

        #expect(throws: McpStoreError.unsupportedFields([McpUnsupportedField(agent: .claude, field: "env.TOKEN", detail: "TOKEN")])) {
            try box.store.apply(.upsert(server), agent: .claude, to: fileSource(config, .project))
        }
        do {
            _ = try box.store.apply(.upsert(server), agent: .claude, to: fileSource(config, .project))
        } catch {
            #expect(error.description == "unsupported_fields:env.TOKEN")
        }
        #expect(box.read("repo/.mcp.json") == "{}")
    }

    @Test func anUnparsableConfigIsNeverWrittenTo() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("repo/opencode.json", #"{"mcp":{}}}}"#)

        do {
            _ = try box.store.apply(.upsert(probe("alethe-probe")), agent: .opencode, to: fileSource(config, .user))
            Issue.record("expected an error")
        } catch {
            #expect(error.description.hasPrefix("unparsable"))
        }
        #expect(box.read("repo/opencode.json") == #"{"mcp":{}}}}"#)
    }

    @Test func jsoncIsRefusedRatherThanStripped() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("repo/opencode.jsonc", "// keep me\n{\"mcp\":{}}")

        #expect(throws: McpStoreError.config(.jsoncUnsupported)) {
            try box.store.apply(.upsert(probe("alethe-probe")), agent: .opencode, to: fileSource(config, .user))
        }
        #expect(box.read("repo/opencode.jsonc")?.contains("// keep me") == true)
    }

    @Test func mutatingAMissingFileReportsNotFound() {
        let box = Sandbox()
        defer { box.cleanUp() }
        #expect(throws: McpStoreError.notFound) {
            try box.store.apply(.remove(name: "ghost"), agent: .codex, to: fileSource(box.url("home/.codex/config.toml"), .user))
        }
        #expect(!FileManager.default.fileExists(atPath: box.url("home/.codex/config.toml").path))
    }

    @Test func backupsAreCapped() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.codex/config.toml", codexRealShape)
        let source = fileSource(config, .user)
        for index in 0..<(ConfigFileWriter.maxBackups + 4) {
            _ = try box.store.apply(.upsert(probe("probe-\(index)")), agent: .codex, to: source)
        }
        #expect(box.store.backups(agent: .codex, source: source).count == ConfigFileWriter.maxBackups)
    }

    @Test func importOwnerMatchesAPrefixedServerName() {
        #expect(AntigravityMcpAdapter.importOwner(of: "codeagentswarm-tasks", imports: ["codeagentswarm"]) == "codeagentswarm")
        #expect(AntigravityMcpAdapter.importOwner(of: "figma", imports: ["codeagentswarm"]) == nil)
    }

    @Test func requestedAgentsFallsBackToEveryAgent() {
        #expect(McpStore.requestedAgents(nil) == McpAgent.allCases)
        #expect(McpStore.requestedAgents(["nonsense"]) == McpAgent.allCases)
        #expect(McpStore.requestedAgents(["codex"]) == [.codex])
        #expect(McpStore.requestedAgents(["agy"]) == [.antigravity])
    }

    @Test func repositoryPathIgnoresBlankInput() {
        #expect(McpStore.repositoryURL(nil) == nil)
        #expect(McpStore.repositoryURL("   ") == nil)
        #expect(McpStore.repositoryURL("/repo") != nil)
    }

    @Test func scanningGlobalScopeReturnsOneSnapshotPerAgent() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let snapshots = try box.store.scanNow(scope: .global, repository: nil)
        #expect(snapshots.map(\.agent) == McpAgent.allCases)
        #expect(snapshots.allSatisfy { $0.scope == .global })
    }

    @Test func aMissingConfigIsNotAnError() {
        let box = Sandbox()
        defer { box.cleanUp() }
        let snapshot = box.store.scanAgent(.codex, scope: .project, repository: box.url("not/a/repo"), imports: [])
        #expect(snapshot.sources.count == 1)
        #expect(snapshot.sources[0].exists == false)
        #expect(snapshot.sources[0].parseError == nil)
        #expect(snapshot.servers.isEmpty)
    }

    @Test func antigravityReportsNoProjectConfig() {
        let box = Sandbox()
        defer { box.cleanUp() }
        let snapshot = box.store.scanAgent(.antigravity, scope: .project, repository: box.repo, imports: [])
        #expect(snapshot.sources.isEmpty)
        #expect(snapshot.servers.isEmpty)
    }
}

// MARK: - Scan

@Suite struct McpStoreScanTests {
    @Test func scanReadsEveryAgentsFileAndMarksImports() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.claude.json", claudeRealShape)
        box.write("home/.codex/config.toml", codexRealShape)
        box.write("home/.gemini/config/mcp_config.json", #"{"mcpServers":{"codeagentswarm-tasks":{"command":"node"},"figma":{"url":"https://x"}}}"#)
        box.write("home/.gemini/config/import_manifest.json", #"{"imports":[{"name":"codeagentswarm"}]}"#)

        let snapshots = try box.store.scanNow(scope: .global, repository: nil)
        let byAgent = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.agent, $0) })
        #expect(byAgent[.claude]?.servers.map(\.server.name) == ["higgsfield"])
        #expect(byAgent[.codex]?.servers.map(\.server.name) == ["discord"])
        let antigravity = try #require(byAgent[.antigravity])
        #expect(antigravity.servers.first { $0.server.name == "codeagentswarm-tasks" }?.managedByImport == "codeagentswarm")
        #expect(antigravity.servers.first { $0.server.name == "figma" }?.managedByImport == nil)
        #expect(byAgent[.cursor]?.sources.first?.exists == false)
        #expect(byAgent[.cursor]?.sources.first?.writable == false)
        #expect(byAgent[.codex]?.sources.first?.modificationDate != nil)
    }

    @Test func aParseErrorMarksTheSourceUnwritableAndHidesTheContent() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.codex/config.toml", "[mcp_servers.broken\ntoken = \"secret-value\"")

        let snapshot = try #require(try box.store.scanNow(scope: .global, repository: nil, agents: [.codex]).first)
        let source = try #require(snapshot.sources.first)
        #expect(source.exists)
        #expect(!source.writable)
        let error = try #require(source.parseError)
        #expect(!error.description.contains("secret-value"))
        #expect(!snapshot.isReadable)
    }

    @Test func theCacheFollowsTheFileAndWrites() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("repo/.mcp.json", #"{"mcpServers":{"a":{"command":"x"}}}"#)
        let first = try box.store.scanNow(scope: .project, repository: box.repo, agents: [.claude])
        #expect(first[0].servers.map(\.server.name) == ["a"])

        box.write("repo/.mcp.json", #"{"mcpServers":{"a":{"command":"x"},"bb":{"command":"y"}}}"#)
        let second = try box.store.scanNow(scope: .project, repository: box.repo, agents: [.claude])
        #expect(second[0].servers.map(\.server.name) == ["a", "bb"])

        _ = try box.store.mutateNow(.remove(name: "bb"), agent: .claude, scope: .project, repository: box.repo)
        let third = try box.store.scanNow(scope: .project, repository: box.repo, agents: [.claude])
        #expect(third[0].servers.map(\.server.name) == ["a"])
    }

    @Test func configPathsListEverySourceOfTheScope() {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("repo/.mcp.json", "{}")
        let paths = box.store.configPathsNow(scope: .project, repository: box.repo)
        #expect(!paths.contains { $0.agent == .antigravity })
        #expect(paths.first { $0.agent == .claude && $0.kind == .project }?.exists == true)
        #expect(paths.first { $0.agent == .codex }?.exists == false)
        #expect(McpStore.capabilities.map(\.agent) == McpAgent.allCases)
    }
}

// MARK: - Source picking and mutations

@Suite struct McpStoreSourcePickingTests {
    @Test func anExistingServerIsEditedWhereItLives() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("repo/.mcp.json", #"{"mcpServers":{"shared":{"command":"x"}}}"#)
        let source = try box.store.pickSource(.claude, scope: .project, repository: box.repo, name: "shared", kind: nil, creating: false)
        #expect(source.kind == .project)
    }

    @Test func aNewServerGoesToTheFirstSource() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let source = try box.store.pickSource(.claude, scope: .project, repository: box.repo, name: "new", kind: nil, creating: true)
        #expect(source.kind == .local)
        #expect(source.projectKey == ClaudeMcpAdapter.projectKey(for: box.repo))
    }

    @Test func aRequestedKindWins() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let source = try box.store.pickSource(.claude, scope: .project, repository: box.repo, name: "new", kind: .project, creating: true)
        #expect(source.kind == .project)
        #expect(throws: McpStoreError.unsupportedScope) {
            try box.store.pickSource(.codex, scope: .project, repository: box.repo, name: "new", kind: .local, creating: true)
        }
        #expect(throws: McpStoreError.unsupportedScope) {
            try box.store.pickSource(.antigravity, scope: .project, repository: box.repo, name: "new", kind: nil, creating: true)
        }
    }

    @Test func aMissingServerIsNotFoundUnlessCreating() {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("repo/.mcp.json", "{ broken")
        #expect(throws: McpStoreError.notFound) {
            try box.store.pickSource(.claude, scope: .project, repository: box.repo, name: "ghost", kind: nil, creating: false)
        }
    }

    @Test func mutateValidatesAndSetsEnabled() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.config/opencode/opencode.json", #"{"theme":"x"}"#)

        _ = try box.store.mutateNow(.upsert(McpServer(name: "  tool  ", transport: .stdio(command: " npx ", arguments: [], cwd: nil))),
                                    agent: .opencode, scope: .global, repository: nil)
        _ = try box.store.mutateNow(.setEnabled(name: "tool", enabled: false), agent: .opencode, scope: .global, repository: nil)

        let servers = try box.store.scanNow(scope: .global, repository: nil, agents: [.opencode])[0].servers
        #expect(servers.map(\.server.name) == ["tool"])
        #expect(servers[0].server.enabled == false)
        #expect(servers[0].server.transport == .stdio(command: "npx", arguments: [], cwd: nil))
        #expect(box.read("home/.config/opencode/opencode.json")?.contains(#""theme""#) == true)
    }

    @Test func disablingWhereTheAgentCannotIsRefused() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.cursor/mcp.json", #"{"mcpServers":{"a":{"command":"x"}}}"#)
        #expect(throws: McpStoreError.config(.unsupportedDisable)) {
            try box.store.mutateNow(.setEnabled(name: "a", enabled: false), agent: .cursor, scope: .global, repository: nil)
        }
    }

    @Test func antigravityImportsWarn() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.gemini/config/import_manifest.json", #"{"imports":[{"name":"swarm"}]}"#)
        let report = try box.store.mutateNow(.upsert(probe("swarm-tasks")), agent: .antigravity, scope: .global, repository: nil)
        #expect(report.warnings == [.managedByImport("swarm")])
    }

    @Test func onlyRemovalNeedsConfirmation() {
        #expect(McpMutation.remove(name: "a").needsConfirmation)
        #expect(!McpMutation.setEnabled(name: "a", enabled: false).needsConfirmation)
        #expect(!McpMutation.upsert(probe("a")).needsConfirmation)
    }

    @Test func validationRefusesNamesNoConfigCanHold() {
        for name in ["", "  ", "a/b", #"a\b"#, #"a"b"#, "a\nb"] {
            #expect(throws: McpStoreError.invalidName) { try McpStore.validated(probe(name)) }
        }
        #expect(throws: McpStoreError.invalidCommand) {
            try McpStore.validated(McpServer(name: "a", transport: .stdio(command: "  ", arguments: [], cwd: nil)))
        }
        #expect(throws: McpStoreError.invalidURL) {
            try McpStore.validated(McpServer(name: "a", transport: .http(url: " ", headers: [:])))
        }
    }

    @Test func validationTrimsAndDropsBlankKeys() throws {
        let server = try McpStore.validated(McpServer(
            name: " a ",
            transport: .sse(url: " https://x ", headers: [" ": .literal("v"), "Auth": .literal("t")]),
            env: [" KEY ": .literal("1"), "": .literal("2")]
        ))
        #expect(server.name == "a")
        #expect(server.transport == .sse(url: "https://x", headers: ["Auth": .literal("t")]))
        #expect(server.env == ["KEY": .literal("1")])
    }
}

// MARK: - Sync, reveal, backups

@Suite struct McpStoreSyncTests {
    @Test func syncReportsWrittenBlockedSkippedAndFailed() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.codex/config.toml", """
            [mcp_servers.swarm]
            command = "npx"
            env_vars = ["SESSION"]

            """)
        box.write("home/.config/opencode/opencode.json", "{}")

        let outcomes = try box.store.syncNow(name: "swarm", from: .codex, to: [.codex, .claude, .opencode, .opencode],
                                             scope: .global, repository: nil)
        #expect(outcomes.map(\.agent) == [.claude, .opencode])
        #expect(outcomes[0].status == .blocked([McpUnsupportedField(agent: .claude, field: "env.SESSION", detail: "SESSION")]))
        guard case .written(let url) = outcomes[1].status else {
            Issue.record("expected a write")
            return
        }
        #expect(url.lastPathComponent == "opencode.json")
        #expect(box.read("home/.config/opencode/opencode.json")?.contains("{env:SESSION}") == true)

        let again = try box.store.syncNow(name: "swarm", from: .codex, to: [.opencode], scope: .global, repository: nil)
        #expect(again[0].status == .skipped)
        let forced = try box.store.syncNow(name: "swarm", from: .codex, to: [.opencode], scope: .global, repository: nil, overwrite: true)
        guard case .written = forced[0].status else {
            Issue.record("expected an overwrite")
            return
        }
    }

    @Test func syncCopiesSecretsWithoutTheCaller() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.codex/config.toml", codexRealShape)
        let outcomes = try box.store.syncNow(name: "discord", from: .codex, to: [.cursor], scope: .global, repository: nil)
        guard case .written = outcomes[0].status else {
            Issue.record("expected a write")
            return
        }
        #expect(box.read("home/.cursor/mcp.json")?.contains("a-live-secret-token-value") == true)
    }

    @Test func syncFailsPerTargetAndNeedsTheSource() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("repo/.mcp.json", #"{"mcpServers":{"a":{"command":"x"}}}"#)
        let outcomes = try box.store.syncNow(name: "a", from: .claude, to: [.antigravity], scope: .project, repository: box.repo)
        #expect(outcomes == [McpSyncOutcome(agent: .antigravity, status: .failed(.unsupportedScope))])
        #expect(throws: McpStoreError.notFound) {
            try box.store.syncNow(name: "ghost", from: .claude, to: [.codex], scope: .project, repository: box.repo)
        }
    }

    @Test func groupsReportGapsOnlyForReadableAgents() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.claude.json", #"{"mcpServers":{"figma":{"url":"https://f"}}}"#)
        box.write("home/.codex/config.toml", "[mcp_servers.figma]\nurl = \"https://f\"\nenabled = false\n\n[mcp_servers.swarm]\ncommand = \"x\"\n")
        box.write("home/.cursor/mcp.json", "{ broken")

        let groups = McpStore.groups(try box.store.scanNow(scope: .global, repository: nil))
        #expect(groups.map(\.name) == ["figma", "swarm"])
        #expect(groups[0].agents == [.claude, .codex])
        #expect(groups[0].missingAgents == [.opencode, .antigravity])
        #expect(groups[0].hasDisabled)
        #expect(groups[1].missingAgents == [.claude, .opencode, .antigravity])
        #expect(McpStore.groups([McpAgentSnapshot(agent: .claude, scope: .global)]).isEmpty)

        let results = box.store.syncAllNow(groups, scope: .global, repository: nil)
        #expect(results.map(\.name) == ["figma", "swarm"])
        let after = McpStore.groups(try box.store.scanNow(scope: .global, repository: nil))
        #expect(after.allSatisfy { $0.missingAgents.isEmpty })
    }

    @Test func revealReturnsOneLiteral() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.write("home/.codex/config.toml", codexRealShape)
        box.write("home/.cursor/mcp.json", #"{"mcpServers":{"r":{"url":"https://r","headers":{"Authorization":"Bearer abc"}}}}"#)

        #expect(try box.store.revealNow(agent: .codex, scope: .global, repository: nil, name: "discord", key: "DISCORD_TOKEN")
            == "a-live-secret-token-value")
        #expect(try box.store.revealNow(agent: .cursor, scope: .global, repository: nil, name: "r", key: "Authorization", header: true)
            == "Bearer abc")
        #expect(throws: McpStoreError.notFound) {
            try box.store.revealNow(agent: .codex, scope: .global, repository: nil, name: "discord", key: "DISCORD_TOKEN", header: true)
        }
        #expect(throws: McpStoreError.notFound) {
            try box.store.revealNow(agent: .codex, scope: .global, repository: nil, name: "discord", key: "MISSING")
        }
    }

    @Test func restorePutsABackupBackAndCanBeUndone() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let config = box.write("home/.codex/config.toml", codexRealShape)
        let source = fileSource(config, .user)
        let report = try box.store.apply(.remove(name: "discord"), agent: .codex, to: source)
        let backup = try #require(report.backup)

        let restored = try box.store.restoreNow(backup, agent: .codex, source: source)
        #expect(box.read("home/.codex/config.toml") == codexRealShape)
        #expect(restored.backup != nil)

        #expect(throws: McpStoreError.backupMismatch) {
            try box.store.restoreNow(backup, agent: .cursor, source: fileSource(box.url("home/.cursor/mcp.json"), .user))
        }
    }

    @Test func projectBackupsAreKeptPerRepository() {
        let box = Sandbox()
        defer { box.cleanUp() }
        let one = box.store.backupSlot(agent: .claude, source: fileSource(box.url("one/.mcp.json"), .project))
        let two = box.store.backupSlot(agent: .claude, source: fileSource(box.url("two/.mcp.json"), .project))
        #expect(one != two)
        #expect(one.name.hasPrefix("claude-project_"))
        #expect(box.store.backupSlot(agent: .claude, source: fileSource(box.url("x"), .local)).name == "claude-local")
    }

    @Test func storeErrorsNeverCarryValues() {
        #expect(McpStoreError.file(.writeFailed(URL(filePath: "/secret"), "detail")).description == "write_failed")
        #expect(McpStoreError.config(.unreadable).description == "unreadable")
    }
}
