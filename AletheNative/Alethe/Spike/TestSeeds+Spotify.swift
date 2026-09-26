#if DEBUG
import AletheIntegrations
import AletheModel
import Foundation

/// `-AletheUITestSeed` cases for Spotify; each hook ignores names it does not own. Both seeds replace
/// the Spotify service with `SeededSpotifySource`, so no test reaches Spotify or opens a browser.
/// - `spotify`: connected, a track playing.
/// - `spotifyOff`: a client ID set, not connected; Connect succeeds at once.
extension TestSeeds {
    static let spotifySeeds: Set<String> = ["spotify", "spotifyOff"]

    /// Into the (empty) workspace being seeded.
    static func seedSpotify(_ name: String, into doc: inout WorkspaceDocument) {}

    /// Into the preferences, with the workspace seed.
    static func seedSpotify(_ name: String, into preferences: inout PreferencesDocument) {
        guard spotifySeeds.contains(name) else { return }
        preferences.spotifyClientID = "seeded-client-id"
    }

    /// Into the running app, once its controllers started (Keychain items, stubs, toggles).
    @MainActor
    static func seedSpotify(_ name: String, environment: AppEnvironment) {
        guard spotifySeeds.contains(name) else { return }
        environment.nowPlaying.model?.replaceSource(SeededSpotifySource(connected: name == "spotify"))
    }
}

/// Answers like Spotify would, from memory.
actor SeededSpotifySource: NowPlayingSource {
    private var connected: Bool

    init(connected: Bool) {
        self.connected = connected
    }

    func isConnected() async -> Bool { connected }

    func login(clientID: String?) async throws(SpotifyError) {
        guard clientID?.isEmpty == false else { throw .missingCredentials }
        connected = true
    }

    func logout() async throws(SpotifyError) {
        connected = false
    }

    func current(clientID: String?) async throws(SpotifyError) -> SpotifyNowPlaying? {
        guard connected else { return nil }
        return SpotifyNowPlaying(
            playing: true, track: "Seeded Track", artist: "Seeded Artist, Second Artist", album: "Seeded Album",
            coverURL: nil, durationMs: 215_000, progressMs: 42_000,
            trackURL: URL(string: "https://open.spotify.com/track/seeded"))
    }
}
#endif
