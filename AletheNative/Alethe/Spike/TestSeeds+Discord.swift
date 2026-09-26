#if DEBUG
import AletheIntegrations
import AletheModel

/// `-AletheUITestSeed` cases for Discord; each hook ignores names it does not own.
/// `discordPresence`: Rich Presence turned on.
extension TestSeeds {
    /// Test launches (`-AletheDataRoot`) talk to this instead of the real Discord.
    static let discordClient: any DiscordPresenceClient = SilentDiscordClient()

    /// Into the (empty) workspace being seeded.
    static func seedDiscord(_ name: String, into doc: inout WorkspaceDocument) {}

    /// Into the preferences, with the workspace seed.
    static func seedDiscord(_ name: String, into preferences: inout PreferencesDocument) {
        if name == "discordPresence" { preferences.discordPresence = true }
    }

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedDiscord(_ name: String, environment: AppEnvironment) {}
}

/// Accepts every activity and sends nothing anywhere.
private struct SilentDiscordClient: DiscordPresenceClient {
    func setActivity(_ activity: DiscordActivity) async -> Bool { true }
    func clearActivity() async {}
}
#endif
