import AletheAgents
import AletheModel
import AletheOrchestrator
import Foundation

/// Connects the orchestrator service to the terminals (upstream `useXtermSession`'s
/// `orchestratorMcpConfigPath` and `agent_events.rs` `/mcp`): the hook listener serves `POST /mcp`
/// through the service, and with the feature on every Claude Code launch registers its tab as a
/// planner and gets the `alethe` HTTP server in its private `--mcp-config` file.
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
        environment.orchestrator.registerPlanner(planner)
        return [OrchestratorPlannerLaunch.server(endpoint: connection.endpoint, token: connection.token, planner: planner.id)]
    }
}
