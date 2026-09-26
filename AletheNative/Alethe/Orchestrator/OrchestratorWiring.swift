import AletheAgents
import AletheModel
import AletheOrchestrator
import Foundation

/// Connects the orchestrator service to the terminals (upstream `useXtermSession`'s
/// `orchestratorMcpConfigPath` and `agent_events.rs` `/mcp`): the hook listener serves `POST /mcp`
/// through the service, and with the feature on every Claude Code or Codex launch registers its tab
/// as a planner. Claude Code gets the `alethe` HTTP server in its private `--mcp-config` file; Codex
/// gets the embedded `alethe-orchestrator-mcp` helper in bridge mode (P6-10, upstream
/// `codex_mcp_config_write` without touching `.codex/config.toml`), pointed at a private file with the
/// endpoint, token and planner.
@MainActor
enum OrchestratorWiring {
    static let providerID = "orchestrator"

    static func start(environment: AppEnvironment) {
        let service = environment.orchestrator
        environment.terminals.hooks.serveMcp { [weak service] body, planner in
            await service?.handleMcp(body: body, planner: planner) ?? .unavailable
        }
        environment.terminals.mcp.register(providerID) { [weak environment] context in
            guard let environment else { return [] }
            return servers(for: context, environment: environment)
        }
    }

    private static func servers(for context: McpLaunchContext, environment: AppEnvironment) -> [McpLaunchServer] {
        guard environment.features.isOn(.orchestrator), OrchestratorPlannerLaunch.supports(context.kind),
              let connection = environment.terminals.hooks.connection else { return [] }
        let tab = context.project.panes.lazy.flatMap(\.tabs).first { $0.id == context.tab }
        let label = tab.map(environment.terminals.displayName(of:)) ?? AgentLabels.name(for: context.kind.rawValue)
        guard let planner = OrchestratorPlannerLaunch.planner(tab: context.tab.rawValue, label: label, kind: context.kind)
        else { return [] }
        guard OrchestratorPlannerLaunch.usesBridge(context.kind) else {
            environment.orchestrator.registerPlanner(planner)
            return [OrchestratorPlannerLaunch.server(endpoint: connection.endpoint, token: connection.token, planner: planner.id)]
        }
        guard let server = bridgeServer(planner: planner.id, endpoint: connection.endpoint, token: connection.token)
        else { return [] }
        environment.orchestrator.registerPlanner(planner)
        return [server]
    }

    /// The helper in bridge mode, once its 0600 bridge file is written; nil when the helper is not
    /// in the bundle or the file cannot be written (the tab then starts without the tools).
    private static func bridgeServer(planner: String, endpoint: String, token: String) -> McpLaunchServer? {
        let helper = OrchestratorPlannerLaunch.helper(inApp: Bundle.main.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let file = AgentHookHub.folder.appending(path: OrchestratorPlannerLaunch.bridgeFileName(tab: planner))
        guard (try? OrchestratorBridgeFile(endpoint: endpoint, token: token, planner: planner).write(to: file)) != nil
        else { return nil }
        return OrchestratorPlannerLaunch.bridgeServer(helper: helper.path, bridgeFile: file.path)
    }
}
