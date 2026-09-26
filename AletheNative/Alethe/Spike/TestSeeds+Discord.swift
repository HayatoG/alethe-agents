#if DEBUG
import AletheModel

/// `-AletheUITestSeed` cases for Discord. A P7-6 slot, filled by P7-13; each hook
/// ignores names it does not own.
extension TestSeeds {
    /// Into the (empty) workspace being seeded.
    static func seedDiscord(_ name: String, into doc: inout WorkspaceDocument) {}

    /// Into the preferences, with the workspace seed.
    static func seedDiscord(_ name: String, into preferences: inout PreferencesDocument) {}

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedDiscord(_ name: String, environment: AppEnvironment) {}
}
#endif
