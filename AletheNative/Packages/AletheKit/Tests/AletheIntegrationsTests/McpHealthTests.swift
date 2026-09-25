import Foundation
import Testing
@testable import AletheIntegrations

// Golden cases from upstream `mcp_health.rs`.
@Suite struct McpHealthParserTests {
    @Test func claudeOutputIsReadLineByLine() {
        let stdout = "Checking MCP server health…\n\n"
            + "claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected\n"
            + "higgsfield: https://mcp.higgsfield.ai/mcp (HTTP) - ! Needs authentication\n"
            + "codeagentswarm-tasks: node C:\\x\\server.js - ✔ Connected\n"
            + "broken: node y.js - ✗ Failed to connect\n"
        let health = McpHealthParser.parseClaude(stdout)
        #expect(health.count == 4)
        #expect(health[0] == McpHealth(name: "claude.ai Gmail", status: .connected))
        #expect(health[1].status == .needsAuth)
        #expect(health[2] == McpHealth(name: "codeagentswarm-tasks", status: .connected))
        #expect(health[3].status == .failed)
    }

    @Test func claudeHeaderLinesAreIgnored() {
        #expect(McpHealthParser.parseClaude("Checking MCP server health…\n\n").isEmpty)
    }

    @Test func claudeUnknownMarkerIsUnknown() {
        #expect(McpHealthParser.parseClaude("x: node a.js - ? Pending\n") == [McpHealth(name: "x", status: .unknown)])
    }

    @Test func codexJSONReportsConfigurationState() {
        let stdout = """
        [
          {"name":"a","enabled":true,"auth_status":"unsupported"},
          {"name":"b","enabled":false,"disabled_reason":"x","auth_status":"unsupported"},
          {"name":"c","enabled":true,"auth_status":"unauthenticated"}
        ]
        """
        let health = McpHealthParser.parseCodex(stdout)
        #expect(health.map(\.status) == [.unknown, .disabled, .needsAuth])
        #expect(health.map(\.name) == ["a", "b", "c"])
    }

    @Test func codexNonJSONOutputIsEmpty() {
        #expect(McpHealthParser.parseCodex("not json at all").isEmpty)
        #expect(McpHealthParser.parseCodex("{\"name\":\"a\"}").isEmpty)
    }

    @Test func opencodeBoxDrawingIsStripped() {
        let stdout = "┌  MCP Servers\n│\n"
            + "●  ✓ codeagentswarm-tasks connected\n"
            + "│      node C:/x/server.js\n│\n"
            + "●  ✗ broken failed\n"
            + "└  2 server(s)\n"
        let health = McpHealthParser.parseOpencode(stdout)
        #expect(health == [
            McpHealth(name: "codeagentswarm-tasks", status: .connected),
            McpHealth(name: "broken", status: .failed),
        ])
    }

    @Test func opencodeAuthStateWinsOverTheMarker() {
        #expect(McpHealthParser.parseOpencode("●  ✗ remote needs auth\n") == [McpHealth(name: "remote", status: .needsAuth)])
    }

    @Test func configOnlyAgentsHaveNoProbe() {
        #expect(McpHealthParser.cli(for: .antigravity) == nil)
        #expect(McpHealthParser.cli(for: .cursor) == nil)
        #expect(McpHealthParser.cli(for: .codex)?.arguments == ["mcp", "list", "--json"])
    }

    @Test func healthPayloadsCarryNoCommandOrURL() throws {
        let stdout = "a: node C:\\secret\\path.js --token=abc123 - ✔ Connected\n"
        let encoded = String(decoding: try JSONEncoder().encode(McpHealthParser.parseClaude(stdout)), as: UTF8.self)
        #expect(!encoded.contains("abc123"))
        #expect(!encoded.contains("secret"))
        #expect(!String(describing: McpHealthParser.parseClaude(stdout)).contains("abc123"))
    }
}

@Suite struct McpHealthCheckerTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, [String], Duration)] = []
        func append(_ item: (String, [String], Duration)) { lock.withLock { items.append(item) } }
        var all: [(String, [String], Duration)] { lock.withLock { items } }
    }

    @Test func runsTheResolvedCLIWithTheTimeoutAndParsesStdoutWhateverTheStatus() async throws {
        let calls = Calls()
        let checker = McpHealthChecker(resolve: { "/opt/bin/\($0)" }) { executable, arguments, timeout throws(ExternalCommandError) in
            calls.append((executable, arguments, timeout))
            return ExternalCommandResult(status: 1, stdout: "x: node a.js - ✗ Failed to connect\n", stderr: "")
        }
        let health = try await checker.check(.claude)
        #expect(health == [McpHealth(name: "x", status: .failed)])
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.0 == "/opt/bin/claude")
        #expect(calls.all.first?.1 == ["mcp", "list"])
        #expect(calls.all.first?.2 == .seconds(45))
    }

    @Test func configOnlyAgentsAreUnsupportedWithoutRunningAnything() async {
        let calls = Calls()
        let checker = McpHealthChecker(resolve: { $0 }) { executable, arguments, timeout throws(ExternalCommandError) in
            calls.append((executable, arguments, timeout))
            return ExternalCommandResult(status: 0, stdout: "", stderr: "")
        }
        for agent in [McpAgent.antigravity, .cursor] {
            await #expect(throws: McpHealthError.unsupportedAgent) { try await checker.check(agent) }
        }
        #expect(calls.all.isEmpty)
    }

    @Test func aMissingCLIIsReported() async {
        let checker = McpHealthChecker(resolve: { _ in nil }) { _, _, _ throws(ExternalCommandError) in
            ExternalCommandResult(status: 0, stdout: "", stderr: "")
        }
        await #expect(throws: McpHealthError.cliNotFound) { try await checker.check(.opencode) }
    }

    @Test func runnerFailuresMapToHealthErrors() async {
        let cases: [(ExternalCommandError, McpHealthError)] = [
            (.timedOut(.seconds(45)), .timedOut),
            (.cancelled, .cancelled),
            (.launchFailed("nope"), .cliFailed),
        ]
        for (thrown, expected) in cases {
            let checker = McpHealthChecker(resolve: { $0 }) { _, _, _ throws(ExternalCommandError) in throw thrown }
            await #expect(throws: expected) { try await checker.check(.codex) }
        }
    }
}
