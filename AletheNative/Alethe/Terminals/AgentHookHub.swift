import AletheAgents
import AletheModel
import Foundation

/// The app side of the hook bridge (P3-9): runs the loopback endpoint, prepares each launch's
/// wiring (a Claude settings file per tab, the Codex forwarder script) and routes incoming events to
/// the terminal registry on the main actor.
@MainActor
final class AgentHookHub {
    private var server: AgentHookServer?
    private var endpoint: String?
    private let folder = FileManager.default.temporaryDirectory.appending(path: "alethe-hooks-\(getpid())", directoryHint: .isDirectory)
    private var codexScript: URL?

    func start(terminals: TerminalRegistry) async {
        guard server == nil else { return }
        let server = AgentHookServer { agent, tab, body in
            let event = agent == "codex" ? AgentHookEvent.codex(body) : AgentHookEvent.claude(body)
            guard let event else { return }
            Task { @MainActor in terminals.apply(event, to: TabID(rawValue: tab)) }
        }
        self.server = server
        endpoint = await server.start()
        guard let endpoint else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let script = folder.appending(path: "codex-notify.sh")
        if (try? Data(AgentHookWiring.codexForwarder(endpoint: endpoint, token: server.token).utf8).write(to: script)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            codexScript = script
        }
    }

    /// Wiring for one launch, or nil when the bridge is not running or the agent has no hooks.
    func launch(for tab: TabID, kind: AgentKind) -> AgentLaunchRequest.HookLaunch? {
        guard let endpoint, let server else { return nil }
        switch kind {
        case .claude:
            let file = folder.appending(path: "claude-\(tab.rawValue).json")
            guard (try? AgentHookWiring.claudeSettings(endpoint: endpoint, token: server.token, tab: tab.rawValue)
                .write(to: file)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return AgentLaunchRequest.HookLaunch(claudeSettingsPath: file.path)
        case .codex:
            guard let codexScript else { return nil }
            return AgentLaunchRequest.HookLaunch(codexArguments: AgentHookWiring.codexArguments(script: codexScript.path, tab: tab.rawValue))
        default:
            return nil
        }
    }

    /// Whether this agent's turns end through hooks (so traffic heuristics must not end them).
    func reportsTurns(_ kind: AgentKind) -> Bool { endpoint != nil && kind == .claude }

    func stop() {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}
