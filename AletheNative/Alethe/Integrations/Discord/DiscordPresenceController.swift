import Observation

/// Discord Rich Presence (PER-4; upstream `useDiscordPresence`). A P7-6 slot, filled by P7-13;
/// `flush` stops it at quit.
@Observable
@MainActor
final class DiscordPresenceController {
    func start(environment: AppEnvironment) {}

    func stop() async {}
}
