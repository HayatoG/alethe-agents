#if DEBUG
import AletheModel

/// `-AletheUITestSeed` cases for remote control. A P7-6 slot, filled by P7-12 (then P7-20); each hook
/// ignores names it does not own.
extension TestSeeds {
    /// Into the (empty) workspace being seeded.
    static func seedRemote(_ name: String, into doc: inout WorkspaceDocument) {}

    /// Into the preferences, with the workspace seed.
    static func seedRemote(_ name: String, into preferences: inout PreferencesDocument) {}

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedRemote(_ name: String, environment: AppEnvironment) {}
}
#endif
