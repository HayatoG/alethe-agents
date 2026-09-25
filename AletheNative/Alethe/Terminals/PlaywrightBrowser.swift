import AletheAgents
import AletheFoundation
import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// The Playwright MCP server in agent launches and the shared browser it can attach to (P5-19;
/// upstream `browser_session.rs`, `playwright_mcp_config_path`). The CDP web pane is not ported
/// (BR-1), so the shared browser shows its own window unless it runs headless.
@Observable
@MainActor
final class PlaywrightBrowser {
    enum State: Hashable {
        case stopped
        case starting
        case running(BrowserSessionInfo)
        case failed(BrowserSessionError?)
    }

    private(set) var state = State.stopped
    @ObservationIgnored private var session: BrowserSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Uses `profileDirectory` for the browser's own profile, and adds the Playwright server to
    /// Claude Code, Codex and OpenCode launches while the feature is on.
    func start(profileDirectory: URL, wiring: McpLaunchWiring, environment: AppEnvironment) {
        session = BrowserSession(profileDirectory: profileDirectory)
        wiring.register(PlaywrightMcp.serverName) { [weak self, weak environment] _ in
            guard let self, let environment, environment.features.isOn(.playwright) else { return [] }
            let preferences = environment.preferences?.document
            let arguments = PlaywrightMcp.arguments(
                mode: preferences.flatMap { $0.playwrightBrowserMode.flatMap(PlaywrightBrowserMode.init(rawValue:)) } ?? .shared,
                dedicatedHeadless: preferences?.playwrightDedicatedHeadless ?? false,
                sharedEndpoint: session?.current?.endpoint)
            return [McpLaunchServer(name: PlaywrightMcp.serverName, command: PlaywrightMcp.command, arguments: arguments)]
        }
    }

    /// Starts the shared browser (or finds it running). Agents launched afterwards attach to it;
    /// ones already running keep what they were launched with.
    func launch(executable: String?, headless: Bool) {
        guard let session, startTask == nil else { return }
        state = .starting
        startTask = Task {
            do {
                let info = try await session.start(executable: executable, headless: headless)
                state = .running(info)
            } catch is CancellationError {
                state = session.current.map(State.running) ?? .stopped
            } catch {
                let reason = error as? BrowserSessionError
                AppLog.shown(reason.map(Self.message) ?? error.localizedDescription, .integrations)
                state = .failed(reason)
            }
            startTask = nil
        }
    }

    /// Stops the shared browser and its processes (also on quit and when the feature is turned off).
    func stop() async {
        startTask?.cancel()
        await session?.stop()
        state = .stopped
    }

    /// Picks up a browser the user quit or that exited on its own.
    func refresh() {
        guard startTask == nil, let session else { return }
        if let info = session.current {
            state = .running(info)
        } else if case .running = state {
            state = .stopped
        }
    }

    static func message(_ error: BrowserSessionError) -> String {
        switch error {
        case .browserNotFound: String(localized: "settings.playwright.error.notFound")
        case .notReady: String(localized: "settings.playwright.error.notReady")
        case .profileDirectory(let reason), .spawnFailed(let reason):
            String(format: String(localized: "settings.playwright.error.other"), reason)
        case .noFreePort: String(localized: "settings.playwright.error.noPort")
        }
    }
}
