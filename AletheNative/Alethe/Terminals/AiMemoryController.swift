import AletheAgents
import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// ai-memory (P5-18, upstream `ai_memory.rs`): detects the CLI and its server, and while the aiMemory
/// feature is on adds `ai-memory mcp` to Claude Code, Codex and OpenCode launches through P5-4.
@Observable
@MainActor
final class AiMemoryController {
    /// `cliPaths` key of the command override (a path chosen in Settings › Features › AI Memory).
    static let overrideKey = "ai-memory"
    static let providerID = "ai-memory"

    /// The last detection; nil until one finished.
    private(set) var status: AiMemoryStatus?
    private(set) var isDetecting = false
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var detection: Task<Void, Never>?

    func start(environment: AppEnvironment) {
        self.environment = environment
        environment.terminals.mcp.register(Self.providerID) { [weak self] _ in
            self?.launchServers() ?? []
        }
        if environment.features.isOn(.aiMemory) { refresh() }
    }

    var override: String? { environment?.preferences?.document.cliPaths?[Self.overrideKey] }

    /// The CLI to run: the override when it is an executable, else `ai-memory` found on disk.
    var executable: String? {
        environment?.launchers.resolve(AiMemory.defaultCommand, override: override)
    }

    /// Detects again (cancels one in flight); runs off the main thread with a timeout.
    func refresh() {
        detection?.cancel()
        let executable = executable
        isDetecting = true
        detection = Task { [weak self] in
            let status = await AiMemory.detect(executable: executable)
            guard !Task.isCancelled, let self else { return }
            self.status = status
            self.isDetecting = false
        }
    }

    func setOverride(_ path: String?) {
        environment?.preferences?.update { preferences in
            var paths = preferences.cliPaths ?? [:]
            paths[Self.overrideKey] = path
            preferences.cliPaths = paths.isEmpty ? nil : paths
        }
        environment?.launchers.invalidate()
        refresh()
    }

    private func launchServers() -> [McpLaunchServer] {
        guard let environment else { return [] }
        let enabled = environment.features.isOn(.aiMemory)
        guard let server = AiMemory.server(enabled: enabled, executable: enabled ? executable : nil, status: status) else {
            return []
        }
        return [McpLaunchServer(name: server.name, command: server.command, arguments: server.arguments)]
    }
}
