import Observation

/// Spotify's current track for the Now Playing views (PER-3; upstream `useNowPlaying`).
/// A P7-6 slot, filled by P7-14.
@Observable
@MainActor
final class NowPlayingController {
    func start(environment: AppEnvironment) {}
}
