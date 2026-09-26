import AletheFoundation
import AppKit
import Foundation

/// The system calls the Spotify service makes, replaceable in tests.
public struct SpotifyDependencies: Sendable {
    public var session: URLSession
    public var environment: @Sendable () -> [String: String]
    /// Opens the authorize URL in the default browser; false when nothing could open it.
    public var openURL: @Sendable (URL) async -> Bool
    /// Waits for the OAuth redirect carrying `state` and returns its `code`. Calls `ready` once it is
    /// listening (the service opens the browser then); `ready` returning false aborts.
    public var awaitCallback: @Sendable (_ state: String, _ ready: @escaping @Sendable () async -> Bool)
        async throws(SpotifyError) -> String
    public var now: @Sendable () -> Date
    public var makeState: @Sendable () -> String
    /// Trace lines; they never carry tokens, codes or secrets.
    public var log: @Sendable (String) -> Void

    public init(session: URLSession,
                environment: @escaping @Sendable () -> [String: String],
                openURL: @escaping @Sendable (URL) async -> Bool,
                awaitCallback: @escaping @Sendable (String, @escaping @Sendable () async -> Bool)
                    async throws(SpotifyError) -> String,
                now: @escaping @Sendable () -> Date = { Date() },
                makeState: @escaping @Sendable () -> String = { Spotify.randomState() },
                log: @escaping @Sendable (String) -> Void = { AppLog.info(.integrations, $0) }) {
        self.session = session
        self.environment = environment
        self.openURL = openURL
        self.awaitCallback = awaitCallback
        self.now = now
        self.makeState = makeState
        self.log = log
    }

    public static func live(pages: SpotifyCallbackPages = .english) -> SpotifyDependencies {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return SpotifyDependencies(
            session: URLSession(configuration: configuration),
            environment: { ProcessInfo.processInfo.environment },
            openURL: { url in await MainActor.run { NSWorkspace.shared.open(url) } },
            awaitCallback: { state, ready throws(SpotifyError) in
                try await SpotifyLoopbackListener(expectedState: state, pages: pages).run(ready: ready)
            }
        )
    }
}

/// Spotify for one profile (upstream `spotify.rs`): login through the loopback redirect, tokens in
/// the Keychain (`spotifyTokens`), refresh, and the current track. Nothing runs on its own; every call
/// is a user action or the Now Playing poll. Off the main thread; cancel the calling task to stop.
public actor SpotifyService {
    public nonisolated let profile: String
    private let secrets: any SecretStore
    private let dependencies: SpotifyDependencies
    private var loggingIn = false

    public init(profile: String, secrets: any SecretStore, dependencies: SpotifyDependencies = .live()) {
        self.profile = profile
        self.secrets = secrets
        self.dependencies = dependencies
    }

    /// `clientID` comes from preferences; the secret from the Keychain; the environment fills blanks.
    public func credentials(clientID: String?) throws(SpotifyError) -> SpotifyCredentials {
        let secret = try secretStore { () throws -> String? in
            try secrets.string(for: .spotifyClientSecret, profile: profile)
        }
        return try SpotifyCredentials.resolve(clientID: clientID, clientSecret: secret,
                                              environment: dependencies.environment())
    }

    /// Upstream `spotify_status`: tokens are stored.
    public func isConnected() -> Bool {
        (try? storedTokens()) != nil
    }

    /// Upstream `spotify_login`: opens the authorize page, waits (5 min) for the redirect on
    /// `127.0.0.1:8888`, exchanges the code and stores the tokens.
    public func login(clientID: String?) async throws(SpotifyError) {
        let credentials = try credentials(clientID: clientID)
        guard !loggingIn else { throw .loginInProgress }
        loggingIn = true
        defer { loggingIn = false }

        let state = dependencies.makeState()
        let url = Spotify.authorizeURL(clientID: credentials.clientID, state: state)
        let openURL = dependencies.openURL
        dependencies.log("spotify: login started")
        let code: String
        do {
            code = try await dependencies.awaitCallback(state) { await openURL(url) }
        } catch {
            dependencies.log("spotify: login ended without a code (\(Self.label(error)))")
            throw error
        }
        if Task.isCancelled { throw .cancelled }

        let response = try await tokenRequest([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Spotify.redirectURI),
            ("client_id", credentials.clientID),
        ], credentials: credentials, refreshing: false)
        guard let refresh = response.refreshToken, !refresh.isEmpty else { throw .missingRefreshToken }
        try save(SpotifyTokens(accessToken: response.accessToken, refreshToken: refresh,
                               expiresAt: dependencies.now().addingTimeInterval(response.expiresIn)))
        dependencies.log("spotify: connected")
    }

    /// Upstream `spotify_logout`: deletes the stored tokens.
    public func logout() throws(SpotifyError) {
        try secretStore { try secrets.delete(.spotifyTokens, profile: profile) }
        dependencies.log("spotify: disconnected")
    }

    /// Upstream `spotify_get_current`: nil when not configured or not connected; a `204` (nothing
    /// playing) or an empty item falls back to the most recently played track, shown paused.
    public func current(clientID: String?) async throws(SpotifyError) -> SpotifyNowPlaying? {
        guard let credentials = try? credentials(clientID: clientID) else { return nil }
        guard let access = try await freshAccessToken(credentials) else { return nil }
        let (data, status) = try await send(bearer(Spotify.nowPlayingURL, access))
        if status == 204 {
            dependencies.log("spotify: nothing playing, reading the recently played track")
            return try await recentlyPlayed(access)
        }
        guard (200..<300).contains(status) else {
            dependencies.log("spotify: now playing failed (status \(status))")
            throw .requestFailed(status: status)
        }
        if let track = SpotifyNowPlaying.parseCurrentlyPlaying(data) { return track }
        return try await recentlyPlayed(access)
    }

    // MARK: - Tokens

    /// Upstream `ensure_fresh_access_token`: refreshes 30 s before expiry; nil when not connected. A
    /// rejected refresh token deletes the tokens (the profile is disconnected).
    func freshAccessToken(_ credentials: SpotifyCredentials) async throws(SpotifyError) -> String? {
        guard let tokens = try storedTokens() else { return nil }
        if tokens.expiresAt.timeIntervalSince(dependencies.now()) > Spotify.refreshMargin {
            return tokens.accessToken
        }
        dependencies.log("spotify: refreshing the access token")
        let response: SpotifyTokenResponse
        do {
            response = try await tokenRequest([
                ("grant_type", "refresh_token"), ("refresh_token", tokens.refreshToken),
                ("client_id", credentials.clientID),
            ], credentials: credentials, refreshing: true)
        } catch .refreshRejected {
            try? secrets.delete(.spotifyTokens, profile: profile)
            dependencies.log("spotify: refresh token rejected, disconnected")
            throw .refreshRejected
        }
        let renewed = SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? tokens.refreshToken,
            expiresAt: dependencies.now().addingTimeInterval(response.expiresIn))
        try save(renewed)
        return renewed.accessToken
    }

    private func tokenRequest(_ fields: [(String, String)], credentials: SpotifyCredentials,
                              refreshing: Bool) async throws(SpotifyError) -> SpotifyTokenResponse {
        var request = URLRequest(url: Spotify.tokenURL)
        request.httpMethod = "POST"
        request.setValue(credentials.basicAuthorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Spotify.formBody(fields)
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else {
            let reason = SpotifyTokenResponse.errorCode(data)
            dependencies.log("spotify: token request failed (status \(status), \(reason ?? "no reason"))")
            if refreshing, status == 401 || (status == 400 && reason == "invalid_grant") { throw .refreshRejected }
            throw .tokenRequestFailed(status: status, reason: reason)
        }
        guard let response = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data),
              !response.accessToken.isEmpty else { throw .invalidResponse }
        return response
    }

    private func storedTokens() throws(SpotifyError) -> SpotifyTokens? {
        try secretStore { try secrets.value(SpotifyTokens.self, for: .spotifyTokens, profile: profile) }
    }

    private func save(_ tokens: SpotifyTokens) throws(SpotifyError) {
        try secretStore { try secrets.setValue(tokens, for: .spotifyTokens, profile: profile) }
    }

    private func secretStore<Value>(_ body: () throws -> Value) throws(SpotifyError) -> Value {
        do {
            return try body()
        } catch SecretStoreError.keychain(let status) {
            throw .secretStore(.keychain(status))
        } catch {
            throw .secretStore(.undecodable)
        }
    }

    // MARK: - Requests

    private func recentlyPlayed(_ access: String) async throws(SpotifyError) -> SpotifyNowPlaying? {
        let (data, status) = try await send(bearer(Spotify.recentlyPlayedURL, access))
        guard (200..<300).contains(status) else {
            dependencies.log("spotify: recently played failed (status \(status))")
            throw .requestFailed(status: status)
        }
        return SpotifyNowPlaying.parseRecentlyPlayed(data)
    }

    private func bearer(_ url: URL, _ access: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws(SpotifyError) -> (Data, Int) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await dependencies.session.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .network(error.code)
        } catch {
            throw Task.isCancelled ? .cancelled : .invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        return (data, http.statusCode)
    }

    /// A log-safe name for an error: the case only, never an associated value that came from outside.
    static func label(_ error: SpotifyError) -> String {
        switch error {
        case .authorizationDenied: "authorizationDenied"
        case .listenerFailed: "listenerFailed"
        case .tokenRequestFailed(let status, _): "tokenRequestFailed \(status)"
        default: String(describing: error)
        }
    }
}
