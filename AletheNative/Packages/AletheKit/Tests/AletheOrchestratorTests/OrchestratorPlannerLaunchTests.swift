import Foundation
import Testing
import AletheAgents
import AletheIntegrations
@testable import AletheOrchestrator

/// Planners and the loopback `/mcp` endpoint (P6-9; upstream `orchestrator_mcp_config_path` and
/// `agent_events.rs` `/mcp`).
@Suite struct OrchestratorPlannerLaunchTests {
    @Test func claudeAndCodexTabsBecomePlanners() {
        #expect(OrchestratorPlannerLaunch.planner(tab: "tab1", label: " Lead ", kind: .claude)
            == Planner(id: "tab1", label: "Lead", agent: "claude"))
        #expect(OrchestratorPlannerLaunch.planner(tab: "tab1", label: "  ", kind: .claude)?.label == "tab1")
        #expect(OrchestratorPlannerLaunch.planner(tab: "tab1", label: "Lead", kind: .codex)
            == Planner(id: "tab1", label: "Lead", agent: "codex"))
        #expect(OrchestratorPlannerLaunch.planner(tab: "tab1", label: "Lead", kind: .shell) == nil)
        #expect(OrchestratorPlannerLaunch.usesBridge(.codex) && !OrchestratorPlannerLaunch.usesBridge(.claude))
    }

    @Test func theServerCarriesTheTokenAndPlannerAsHeaders() {
        let server = OrchestratorPlannerLaunch.server(endpoint: "http://127.0.0.1:5000/", token: "tok", planner: "tab1")
        #expect(server.name == "alethe")
        #expect(server.url == "http://127.0.0.1:5000/mcp")
        #expect(server.headers == ["X-Alethe-Token": "tok", "X-Alethe-Planner": "tab1"])
        #expect(server.arguments.isEmpty && server.environment.isEmpty)
        // Never passed as arguments: agents taking servers on the command line skip HTTP ones.
        #expect(McpLaunchConfig.codexArguments([server]).isEmpty)
    }

    @Test func aRegisteredPlannerShowsInTheSnapshot() async {
        let core = OrchestratorCore()
        let planner = OrchestratorPlannerLaunch.planner(tab: "tab1", label: "Lead", kind: .claude)!
        await core.registerPlanner(planner)
        await core.registerPlanner(Planner(id: "tab1", label: "Renamed", agent: "claude"))
        #expect(await core.snapshot().planners == [Planner(id: "tab1", label: "Renamed", agent: "claude")])
    }

    /// P: a planner's tool call over the loopback listener, as Claude Code sends it, reaches the core
    /// and its answer comes back; a notification gets 202 and a request without the token 401.
    @Test func aToolCallRoundTripsOverLoopback() async throws {
        let core = OrchestratorCore()
        await core.registerPlanner(Planner(id: "tab1", label: "Lead", agent: "claude"))
        let server = AgentHookServer(token: "secret") { _, _, _ in }
        server.setMcpHandler { body, planner in
            guard let reply = await OrchestratorMCP.handle(body: body, planner: planner, handler: core) else { return .accepted }
            return .body(reply)
        }
        let endpoint = try #require(await server.start())
        defer { server.stop() }
        let config = OrchestratorPlannerLaunch.server(endpoint: endpoint, token: server.token, planner: "tab1")
        let url = try #require(config.url.flatMap(URL.init(string:)))

        func post(_ body: String, token: String? = nil) async throws -> (status: Int, body: String) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
            if let token { request.setValue(token, forHTTPHeaderField: OrchestratorPlannerLaunch.tokenHeader) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }

        let initialize = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(initialize.status == 200 && initialize.body.contains(#""protocolVersion":"2025-06-18""#))

        let status = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"alethe_status","arguments":{}}}"#)
        #expect(status.status == 200)
        let result = try #require(try OrderedJSON.parse(Data(status.body.utf8)).objectValue?["result"]?.objectValue)
        let text = try #require(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        let snapshot = try #require(try OrderedJSON.parse(Data(text.utf8)).objectValue)
        #expect(snapshot["planners"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "tab1")
        #expect(snapshot["concurrencyLimit"] != nil)

        let delegated = try await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"alethe_delegate","arguments":{"tasks":[]}}}"#)
        #expect(delegated.status == 200 && delegated.body.contains(#""isError":true"#))

        #expect(try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).status == 202)
        #expect(try await post(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#, token: "wrong").status == 401)
        await core.shutdown()
    }
}
