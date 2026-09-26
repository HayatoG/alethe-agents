import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// Discord Rich Presence (PER-4; upstream `useDiscordPresence`): while `discordPresence` is on,
/// "Working with Alethe" with the current view and the launch time, refreshed every 30 s and on view
/// changes; cleared when turned off and at quit (`flush`). Never sends project names.
@Observable
@MainActor
final class DiscordPresenceController {
    @ObservationIgnored private var session: DiscordPresenceSession?
    /// Upstream's `STARTED_AT`: the controller is created at launch.
    @ObservationIgnored private let launchedAt = Date()

    func start(environment: AppEnvironment) {
        guard session == nil else { return }
        session = DiscordPresenceSession(client: Self.makeClient(), startedAt: launchedAt)
        follow(environment)
    }

    func stop() async {
        await session?.stop()
    }

    /// Re-applied whenever the preference or what is in front changes.
    private func follow(_ environment: AppEnvironment) {
        let (enabled, view) = withObservationTracking {
            (environment.preferences?.document.showsDiscordPresence ?? false, Self.view(in: environment))
        } onChange: { [weak self, weak environment] in
            Task { @MainActor in
                guard let self, let environment else { return }
                self.follow(environment)
            }
        }
        session?.update(enabled: enabled, view: view)
    }

    /// Home → the dashboard; an orchestration board focused in the workspace → orchestration;
    /// otherwise the terminals.
    static func view(in environment: AppEnvironment) -> DiscordPresenceView {
        if environment.showingHome { return .dashboard }
        guard let document = environment.workspace?.document,
              let paneID = environment.focusModePaneID ?? document.workspace.focusedPaneID,
              let found = document.pane(paneID),
              found.project.id == document.workspace.selectedProjectID
        else { return .terminals }
        if case .orchestrator = found.pane.content { return .orchestration }
        return .terminals
    }

    private static func makeClient() -> any DiscordPresenceClient {
        #if DEBUG
        // Test launches must not show on the developer's Discord.
        if UserDefaults.standard.string(forKey: "AletheDataRoot") != nil { return TestSeeds.discordClient }
        #endif
        return DiscordIPCClient()
    }
}
