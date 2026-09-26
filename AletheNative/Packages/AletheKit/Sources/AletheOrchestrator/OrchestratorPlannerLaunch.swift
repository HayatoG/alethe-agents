import Foundation
import AletheAgents

/// How an agent terminal becomes a planner (upstream `orchestrator_mcp_config_path`): the tab is
/// registered with the core, and its launch gets an `alethe` MCP server pointing at the app's
/// loopback `/mcp`, with the token and the planner id as headers. Claude Code only here; Codex
/// planners go through the stdio bridge (P6-10).
public enum OrchestratorPlannerLaunch {
    public static let serverName = OrchestratorMCP.serverName
    public static let tokenHeader = "X-Alethe-Token"
    public static let plannerHeader = "X-Alethe-Planner"

    /// Agents that take the HTTP server per launch.
    public static func supports(_ kind: AgentKind) -> Bool { kind == .claude }

    /// The planner for a tab: its id is the tab's, its label the tab's display name.
    public static func planner(tab: String, label: String, kind: AgentKind) -> Planner? {
        guard supports(kind) else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return Planner(id: tab, label: trimmed.isEmpty ? tab : trimmed, agent: kind.rawValue)
    }

    /// The per-launch server. One config per terminal, so a request says which planner sent it.
    /// The token only ever reaches the private per-launch file.
    public static func server(endpoint: String, token: String, planner: String) -> McpLaunchServer {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return .http(name: serverName, url: "\(base)/mcp", headers: [tokenHeader: token, plannerHeader: planner])
    }
}
