import AletheFoundation
import AletheIntegrations
import AppKit
import Foundation
import Observation

/// Spotify's current track for the Now Playing views (PER-3; upstream `useNowPlaying`). Nothing is read
/// until a Now Playing view appears; the poll runs only while one is visible and the app is active.
@Observable
@MainActor
final class NowPlayingController {
    /// Created by `start`; nil before the profile loaded.
    private(set) var model: NowPlayingModel?
    /// Whether a client secret is stored in the Keychain; nil until read (Settings).
    private(set) var hasClientSecret: Bool?
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var secrets: (any SecretStore)?
    @ObservationIgnored private var profile = ""
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(environment: AppEnvironment) {
        guard model == nil, let profileID = environment.profileID, let locations = environment.locations else { return }
        self.environment = environment
        let secrets = KeychainStore.forLaunch()
        self.secrets = secrets
        profile = profileID.rawValue
        let service = SpotifyService(profile: profile, secrets: secrets,
                                     dependencies: .live(pages: Self.callbackPages))
        let store = NowPlayingLastTrackStore(
            url: locations.profileDirectory(profileID).appending(path: NowPlayingLastTrackStore.fileName))
        let model = NowPlayingModel(source: service, lastTrack: store)
        model.clientID = { [weak environment] in environment?.preferences?.document.spotifyClientID }
        model.setAppActive(NSApp?.isActive ?? true)
        self.model = model
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setAppActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setAppActive(false) }
            },
        ]
        Task { await model.restoreLastTrack() }
    }

    var isConnecting: Bool { model?.connecting ?? false }

    /// Login through the browser (up to 5 minutes); `cancelConnect` stops waiting.
    func connect() {
        guard let model, connectTask == nil else { return }
        connectTask = Task { [weak self] in
            await model.connect()
            self?.connectTask = nil
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
    }

    func disconnect() {
        guard let model else { return }
        connectTask?.cancel()
        Task { await model.disconnect() }
    }

    // MARK: - Client secret

    /// Reads whether a secret is stored (never the value into the UI), off the main thread.
    func loadSecretStatus() {
        guard let secrets else { return }
        let profile = profile
        Task {
            let stored = await Task.detached(priority: .utility) {
                ((try? secrets.string(for: .spotifyClientSecret, profile: profile)) ?? nil).map { !$0.isEmpty } ?? false
            }.value
            hasClientSecret = stored
        }
    }

    /// Stores (or, when blank, removes) the client secret in the Keychain, off the main thread.
    func setClientSecret(_ value: String) {
        guard let secrets else { return }
        let profile = profile
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    if trimmed.isEmpty {
                        try secrets.delete(.spotifyClientSecret, profile: profile)
                    } else {
                        try secrets.setString(trimmed, for: .spotifyClientSecret, profile: profile)
                    }
                    return true
                } catch {
                    AppLog.record(.error, .integrations, "Spotify client secret not saved: \(error)")
                    return false
                }
            }.value
            if ok { hasClientSecret = !trimmed.isEmpty }
        }
    }

    // MARK: - Text

    private static var callbackPages: SpotifyCallbackPages {
        SpotifyCallbackPages(
            successTitle: String(localized: "spotify.callback.success.title"),
            successMessage: String(localized: "spotify.callback.success.message"),
            failureTitle: String(localized: "spotify.callback.failure.title"),
            failureMessage: String(localized: "spotify.callback.failure.message"))
    }

    /// A user-facing sentence for a Spotify error; never carries a token or response body.
    static func message(_ error: SpotifyError) -> String {
        switch error {
        case .missingCredentials: String(localized: "spotify.error.missingCredentials")
        case .loginInProgress: String(localized: "spotify.error.loginInProgress")
        case .portBusy: String(localized: "spotify.error.portBusy")
        case .browserUnavailable: String(localized: "spotify.error.browser")
        case .timedOut: String(localized: "spotify.error.timedOut")
        case .cancelled: String(localized: "spotify.error.cancelled")
        case .stateMismatch: String(localized: "spotify.error.stateMismatch")
        case .authorizationDenied: String(localized: "spotify.error.denied")
        case .refreshRejected: String(localized: "spotify.error.refreshRejected")
        case .network: String(localized: "spotify.error.network")
        case .secretStore: String(localized: "spotify.error.keychain")
        case .tokenRequestFailed(let status, _), .requestFailed(let status):
            String(format: String(localized: "spotify.error.status"), status)
        case .listenerFailed, .missingCode, .missingRefreshToken, .invalidResponse:
            String(localized: "spotify.error.generic")
        }
    }
}
