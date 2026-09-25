import Foundation
import Testing
@testable import AletheIntegrations

/// The MCP manager's form (P5-25): a stored secret is never shown and survives an edit untouched.
@Suite struct McpDraftTests {
    private func secretServer() -> McpServer {
        McpServer(
            name: "alpha",
            transport: .stdio(command: "npx", arguments: ["-y", "alpha-mcp"], cwd: nil),
            env: ["API_KEY": .literal("sk-live-0123456789abcdef"), "HOME_DIR": .passthrough("HOME")],
            enabled: false,
            timeouts: McpTimeouts(startupSeconds: 10)
        )
    }

    @Test func editingShowsNoStoredLiteral() {
        let draft = McpServerDraft(editing: secretServer())
        let key = draft.env.first { $0.key == "API_KEY" }
        #expect(key?.value == "")
        #expect(key?.secret == true)
        #expect(key?.storedPreview == "••••••••cdef")
        #expect(draft.env.first { $0.key == "HOME_DIR" }?.value == "HOME")
        #expect(draft.arguments == "-y\nalpha-mcp")
        #expect(draft.isEditing)
    }

    @Test func anUntouchedEditKeepsEverything() throws {
        let server = secretServer()
        #expect(try McpServerDraft(editing: server).server() == server)
    }

    @Test func aTypedValueReplacesTheStoredOne() throws {
        var draft = McpServerDraft(editing: secretServer())
        let index = try #require(draft.env.firstIndex { $0.key == "API_KEY" })
        draft.env[index].value = "new-value"
        draft.arguments = "alpha-mcp\n\n  --verbose  "
        let server = try draft.server()
        #expect(server.env["API_KEY"] == .literal("new-value"))
        #expect(server.env["HOME_DIR"] == .passthrough("HOME"))
        #expect(server.transport == .stdio(command: "npx", arguments: ["alpha-mcp", "--verbose"], cwd: nil))
        #expect(server.enabled == false, "fields the form does not show are kept")
        #expect(server.timeouts.startupSeconds == 10)
    }

    @Test func removedAndBlankRowsAreDropped() throws {
        var draft = McpServerDraft(editing: secretServer())
        draft.env.removeAll { $0.key == "HOME_DIR" }
        draft.env.append(McpEnvDraft())
        let server = try draft.server()
        #expect(server.env.keys.sorted() == ["API_KEY"])
    }

    @Test func passthroughRowsNameTheHostVariable() throws {
        var draft = McpServerDraft()
        draft.name = " beta "
        draft.command = "uvx"
        draft.arguments = "beta-mcp"
        draft.env = [McpEnvDraft(key: "TOKEN", passthrough: true), McpEnvDraft(key: "REGION", value: "eu")]
        let server = try draft.server()
        #expect(server.name == "beta")
        #expect(server.env["TOKEN"] == .passthrough("TOKEN"))
        #expect(server.env["REGION"] == .literal("eu"))
        #expect(server.enabled)
    }

    @Test func aRegistryOptionPrefillsWithoutSecrets() throws {
        let option = McpInstallOption(kind: .http, label: "Remote", url: "https://mcp.example.com/mcp", headers: [
            McpEnvHint(name: "Authorization", description: "Bearer token", secret: true, required: true),
            McpEnvHint(name: "X-Region", default: "us"),
        ])
        var draft = McpServerDraft(option: option, name: "example")
        #expect(draft.kind == .http)
        #expect(draft.headers.map(\.value) == ["", "us"])
        #expect(draft.missingRequired == ["Authorization"])
        draft.headers[0].value = "Bearer abc"
        #expect(draft.missingRequired.isEmpty)
        let server = try draft.server()
        #expect(server.transport.headers?["Authorization"] == .literal("Bearer abc"))
        #expect(server.transport.summary == "https://mcp.example.com/mcp")
    }

    @Test func invalidFormsAreRefused() {
        var draft = McpServerDraft()
        draft.name = "a/b"
        draft.command = "npx"
        #expect(throws: McpStoreError.invalidName) { try draft.server() }
        draft.name = "ok"
        draft.command = " "
        #expect(throws: McpStoreError.invalidCommand) { try draft.server() }
        draft.kind = .sse
        #expect(throws: McpStoreError.invalidURL) { try draft.server() }
    }

    @Test func groupsMatchNameAgentAndSummary() {
        let record = McpServerRecord(server: secretServer(), agent: .codex, scope: .global, sourceKind: .user,
                                     sourceURL: URL(filePath: "/tmp/config.toml"))
        let group = McpStore.groups([McpAgentSnapshot(agent: .codex, scope: .global, servers: [record])])[0]
        #expect(group.matches("ALP"))
        #expect(group.matches("codex"))
        #expect(group.matches("alpha-mcp"))
        #expect(!group.matches("sk-live"), "env values are never searched")
        #expect(group.isOn(anyOf: []))
        #expect(group.isOn(anyOf: [.codex, .claude]))
        #expect(!group.isOn(anyOf: [.cursor]))
    }

    @Test func snapshotIssues() {
        let url = URL(filePath: "/tmp/x.json")
        #expect(McpAgentSnapshot(agent: .antigravity, scope: .project).issue == .unsupported)
        #expect(McpAgentSnapshot(agent: .claude, scope: .global, sources: [
            McpSourceState(kind: .user, url: url, exists: false, writable: true),
        ]).issue == .missing)
        #expect(McpAgentSnapshot(agent: .claude, scope: .global, sources: [
            McpSourceState(kind: .user, url: url, exists: true, writable: false, parseError: .rootNotAnObject),
        ]).issue == .unreadable)
        let readOnly = McpAgentSnapshot(agent: .claude, scope: .global, sources: [
            McpSourceState(kind: .user, url: url, exists: true, writable: false),
        ])
        #expect(readOnly.issue == .readOnly)
        #expect(!readOnly.isWritable)
        #expect(McpAgentSnapshot(agent: .claude, scope: .global, sources: [
            McpSourceState(kind: .user, url: url, exists: true, writable: true),
        ]).issue == nil)
    }

    @Test func aRecordFindsItsSource() throws {
        let home = McpHome(home: URL(filePath: "/tmp/alethe-draft-home", directoryHint: .isDirectory))
        let store = McpStore(home: home, writer: ConfigFileWriter(backupRoot: URL(filePath: "/tmp/alethe-draft-backups")))
        let repo = URL(filePath: "/tmp/alethe-draft-repo", directoryHint: .isDirectory)
        let local = try #require(store.sources(for: .claude, scope: .project, repository: repo).first)
        let record = McpServerRecord(server: secretServer(), agent: .claude, scope: .project, sourceKind: .local,
                                     sourceURL: local.url)
        #expect(store.source(of: record, repository: repo) == local)
        #expect(local.projectKey != nil)
        #expect(store.source(of: record, repository: nil) == nil)
    }
}
