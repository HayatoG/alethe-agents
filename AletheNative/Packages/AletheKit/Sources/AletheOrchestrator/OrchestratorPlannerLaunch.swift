import Foundation
import AletheAgents

/// How an agent terminal becomes a planner (upstream `orchestrator_mcp_config_path` and
/// `codex_mcp_config_write`): the tab is registered with the core, and its launch gets an `alethe`
/// MCP server reaching the app's loopback `/mcp` with the token and the planner id. Claude Code
/// takes an HTTP server in its private `--mcp-config` file; Codex, which takes servers as `-c`
/// arguments, gets the stdio helper in bridge mode, pointed at a private file holding the token.
public enum OrchestratorPlannerLaunch {
    public static let serverName = OrchestratorMCP.serverName
    public static let tokenHeader = "X-Alethe-Token"
    public static let plannerHeader = "X-Alethe-Planner"
    /// The stdio helper's executable, embedded in the app under `Contents/Helpers/`.
    public static let helperName = "alethe-orchestrator-mcp"
    public static let bridgeFlag = "--bridge"

    /// Agents that can plan: Claude Code over HTTP, Codex over the stdio bridge.
    public static func supports(_ kind: AgentKind) -> Bool { kind == .claude || kind == .codex }

    /// Agents reached through the stdio helper instead of an HTTP server.
    public static func usesBridge(_ kind: AgentKind) -> Bool { kind == .codex }

    /// The planner for a tab: its id is the tab's, its label the tab's display name.
    public static func planner(tab: String, label: String, kind: AgentKind) -> Planner? {
        guard supports(kind) else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return Planner(id: tab, label: trimmed.isEmpty ? tab : trimmed, agent: kind.rawValue)
    }

    /// The per-launch HTTP server. One config per terminal, so a request says which planner sent it.
    /// The token only ever reaches the private per-launch file.
    public static func server(endpoint: String, token: String, planner: String) -> McpLaunchServer {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return .http(name: serverName, url: "\(base)/mcp", headers: [tokenHeader: token, plannerHeader: planner])
    }

    /// The per-launch stdio server for the helper in bridge mode. Only the bridge file's path is an
    /// argument; the token stays in that 0600 file.
    public static func bridgeServer(helper: String, bridgeFile: String) -> McpLaunchServer {
        McpLaunchServer(name: serverName, command: helper, arguments: [bridgeFlag, bridgeFile])
    }

    /// The helper inside an app bundle.
    public static func helper(inApp bundle: URL) -> URL {
        bundle.appending(path: "Contents/Helpers/\(helperName)")
    }

    /// The bridge file's name for a tab, safe for any tab id.
    public static func bridgeFileName(tab: String) -> String {
        let safe = String(tab.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return "orchestrator-bridge-\(safe.isEmpty ? "_" : safe).json"
    }
}
