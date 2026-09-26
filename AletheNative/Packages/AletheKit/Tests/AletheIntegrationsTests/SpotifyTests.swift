import AletheFoundation
import Foundation
import Synchronization
import Testing
@testable import AletheIntegrations

/// G: upstream `spotify.rs` tests.
struct SpotifyGoldenTests {
    @Test func parsesRecentTrackAsPausedNowPlaying() throws {
        let item: [String: Any] = [
            "name": "A Track",
            "artists": [["name": "An Artist"]],
            "album": [
                "name": "An Album",
                "images": [["url": "https://example.com/large.jpg"], ["url": "https://example.com/small.jpg"]],
            ],
            "duration_ms": 123_000,
            "external_urls": ["spotify": "https://open.spotify.com/track/example"],
        ]
        let parsed = try #require(SpotifyNowPlaying.parse(item: item, playing: false, progressMs: 0))
        #expect(!parsed.playing)
        #expect(parsed.track == "A Track")
        #expect(parsed.artist == "An Artist")
        #expect(parsed.coverURL?.absoluteString == "https://example.com/small.jpg")
    }
}

struct SpotifyAPITests {
    @Test func authorizeURLCarriesScopesLoopbackRedirectAndState() {
        let url = Spotify.authorizeURL(clientID: "client id", state: "st_ate-1")
        #expect(url.absoluteString == "https://accounts.spotify.com/authorize?response_type=code&client_id=client%20id"
            + "&scope=user-read-currently-playing%20user-read-playback-state%20user-read-recently-played"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&state=st_ate-1")
    }

    @Test func randomStateIsLongAndUnpredictable() {
        let first = Spotify.randomState(), second = Spotify.randomState()
        #expect(first.count == 24)
        #expect(first != second)
    }

    @Test func credentialsPreferTheAppAndFallBackToTheEnvironment() throws {
        let environment = ["SPOTIFY_CLIENT_ID": "env-id", "SPOTIFY_CLIENT_SECRET": "env-secret"]
        let app = try SpotifyCredentials.resolve(clientID: " app-id ", clientSecret: "app-secret", environment: environment)
        #expect(app == SpotifyCredentials(clientID: "app-id", clientSecret: "app-secret"))
        let fallback = try SpotifyCredentials.resolve(clientID: "  ", clientSecret: nil, environment: environment)
        #expect(fallback == SpotifyCredentials(clientID: "env-id", clientSecret: "env-secret"))
    }

    @Test func credentialsNeedBothValues() {
        #expect(throws: SpotifyError.missingCredentials) {
            try SpotifyCredentials.resolve(clientID: "id", clientSecret: nil, environment: [:])
        }
        #expect(throws: SpotifyError.missingCredentials) {
            try SpotifyCredentials.resolve(clientID: nil, clientSecret: "secret", environment: [:])
        }
    }

    @Test func credentialsNeverPrintTheSecret() {
        let credentials = SpotifyCredentials(clientID: "id", clientSecret: "very-secret-value")
        #expect(!String(describing: credentials).contains("very-secret-value"))
        #expect(!String(describing: SpotifyTokens(accessToken: "acc-XYZ", refreshToken: "ref-XYZ", expiresAt: .now))
            .contains("XYZ"))
    }

    @Test func currentlyPlayingParsesPlaybackState() throws {
        let json = #"{"is_playing":true,"progress_ms":4200,"item":{"name":"Song","artists":[{"name":"A"},{"name":"B"}],"album":{"name":"LP","images":[]},"duration_ms":9000}}"#
        let track = try #require(SpotifyNowPlaying.parseCurrentlyPlaying(Data(json.utf8)))
        #expect(track.playing)
        #expect(track.progressMs == 4200)
        #expect(track.artist == "A, B")
        #expect(track.album == "LP")
        #expect(track.coverURL == nil)
        #expect(track.durationMs == 9000)
    }

    @Test func currentlyPlayingWithoutAnItemIsNil() {
        #expect(SpotifyNowPlaying.parseCurrentlyPlaying(Data(#"{"is_playing":false,"item":null}"#.utf8)) == nil)
    }
}

struct SpotifyCallbackTests {
    private let state = "expected-state"

    @Test func returnsTheCodeWhenTheStateMatches() {
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callback?code=abc%2F1&state=expected-state",
                                         expectedState: state) == .code("abc/1"))
    }

    @Test func otherPathsAreNotFoundAndKeepWaiting() {
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/favicon.ico", expectedState: state) == .notFound)
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callbackx?code=a&state=expected-state",
                                         expectedState: state) == .notFound)
        #expect(SpotifyCallback.evaluate(method: "GET", target: "http://evil/callback", expectedState: state) == .notFound)
    }

    @Test func nonGetCallbacksAreRejected() {
        #expect(SpotifyCallback.evaluate(method: "POST", target: "/callback?code=a&state=expected-state",
                                         expectedState: state) == .invalid)
    }

    @Test func aStateMismatchFailsTheLogin() {
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callback?code=a&state=other",
                                         expectedState: state) == .failure(.stateMismatch))
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callback?code=a", expectedState: state)
            == .failure(.stateMismatch))
    }

    @Test func anAuthorizeErrorIsReported() {
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callback?error=access_denied&state=expected-state",
                                         expectedState: state) == .failure(.authorizationDenied("access_denied")))
    }

    @Test func aCallbackWithoutACodeFails() {
        #expect(SpotifyCallback.evaluate(method: "GET", target: "/callback?state=expected-state",
                                         expectedState: state) == .failure(.missingCode))
    }

    @Test func theReturnPageEscapesItsText() {
        let pages = SpotifyCallbackPages(successTitle: "<b>", successMessage: "a & b", failureTitle: "x",
                                         failureMessage: "y")
        let html = pages.html(success: true)
        #expect(html.contains("&lt;b&gt;"))
        #expect(html.contains("a &amp; b"))
    }
}

// MARK: - Service over a URLProtocol stub

/// Answers every request of a stubbed session; records what was sent.
final class SpotifyStubProtocol: URLProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: String
    }

    typealias Responder = @Sendable (Sent) -> (status: Int, body: String)

    static let responder = Mutex<Responder?>(nil)
    static let sent = Mutex<[Sent]>([])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = Sent(url: request.url!, method: request.httpMethod ?? "GET",
                          headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        Self.sent.withLock { $0.append(record) }
        let (status, body) = Self.responder.withLock { $0 }?(record) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// U: the service over the stub, with the loopback callback stubbed too. Serialized: one responder.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpotifyServiceTests {
    private let profile = "default"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(secrets: InMemorySecretStore, code: String = "the-auth-code") -> (SpotifyService, @Sendable () -> [String]) {
        SpotifyStubProtocol.sent.withLock { $0 = [] }
        let lines = Mutex<[String]>([])
        let now = start
        let dependencies = SpotifyDependencies(
            session: SpotifyStubProtocol.session(),
            environment: { [:] },
            openURL: { _ in true },
            awaitCallback: { _, ready throws(SpotifyError) in
                guard await ready() else { throw .browserUnavailable }
                return code
            },
            now: { now },
            makeState: { "fixed-state" },
            log: { line in lines.withLock { $0.append(line) } })
        return (SpotifyService(profile: profile, secrets: secrets, dependencies: dependencies),
                { lines.withLock { $0 } })
    }

    private func configured() throws -> InMemorySecretStore {
        let secrets = InMemorySecretStore()
        try secrets.setString("the-client-secret", for: .spotifyClientSecret, profile: profile)
        return secrets
    }

    private func sent() -> [SpotifyStubProtocol.Sent] { SpotifyStubProtocol.sent.withLock { $0 } }

    @Test func loginExchangesTheCodeWithBasicAuthAndStoresTokensInTheKeychain() async throws {
        let secrets = try configured()
        SpotifyStubProtocol.responder.withLock { $0 = { _ in
            (200, #"{"access_token":"ACCESS-1","expires_in":3600,"refresh_token":"REFRESH-1"}"#)
        } }
        let (service, logs) = service(secrets: secrets)
        try await service.login(clientID: "the-client-id")

        let request = try #require(sent().first)
        #expect(request.url == Spotify.tokenURL)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"]
            == "Basic " + Data("the-client-id:the-client-secret".utf8).base64EncodedString())
        #expect(request.body == "grant_type=authorization_code&code=the-auth-code"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&client_id=the-client-id")
        let tokens = try #require(try secrets.value(SpotifyTokens.self, for: .spotifyTokens, profile: profile))
        #expect(tokens == SpotifyTokens(accessToken: "ACCESS-1", refreshToken: "REFRESH-1",
                                        expiresAt: start.addingTimeInterval(3600)))
        #expect(await service.isConnected())
        for line in logs() {
            for secret in ["ACCESS-1", "REFRESH-1", "the-auth-code", "the-client-secret", "fixed-state"] {
                #expect(!line.contains(secret))
            }
        }
    }

    @Test func loginWithoutARefreshTokenFails() async throws {
        let secrets = try configured()
        SpotifyStubProtocol.responder.withLock { $0 = { _ in (200, #"{"access_token":"A","expires_in":3600}"#) } }
        let (service, _) = service(secrets: secrets)
        await #expect(throws: SpotifyError.missingRefreshToken) { try await service.login(clientID: "id") }
        #expect(await !service.isConnected())
    }

    @Test func loginWithoutCredentialsNeverOpensTheBrowser() async {
        let (service, _) = service(secrets: InMemorySecretStore())
        await #expect(throws: SpotifyError.missingCredentials) { try await service.login(clientID: "id") }
        #expect(sent().isEmpty)
    }

    @Test func aFailedExchangeReportsSpotifysErrorCodeOnly() async throws {
        let secrets = try configured()
        SpotifyStubProtocol.responder.withLock { $0 = { _ in
            (400, #"{"error":"invalid_client","error_description":"Invalid client secret"}"#)
        } }
        let (service, _) = service(secrets: secrets)
        await #expect(throws: SpotifyError.tokenRequestFailed(status: 400, reason: "invalid_client")) {
            try await service.login(clientID: "id")
        }
    }

    @Test func aTokenValidForMoreThan30SecondsIsUsedAsIs() async throws {
        let secrets = try configured()
        try secrets.setValue(SpotifyTokens(accessToken: "OLD", refreshToken: "R", expiresAt: start.addingTimeInterval(31)),
                             for: .spotifyTokens, profile: profile)
        SpotifyStubProtocol.responder.withLock { $0 = { _ in (500, "") } }
        let (service, _) = service(secrets: secrets)
        let access = try await service.freshAccessToken(SpotifyCredentials(clientID: "id", clientSecret: "s"))
        #expect(access == "OLD")
        #expect(sent().isEmpty)
    }

    @Test func aTokenWithin30SecondsOfExpiryIsRefreshedKeepingTheRefreshToken() async throws {
        let secrets = try configured()
        try secrets.setValue(SpotifyTokens(accessToken: "OLD", refreshToken: "KEEP", expiresAt: start.addingTimeInterval(29)),
                             for: .spotifyTokens, profile: profile)
        SpotifyStubProtocol.responder.withLock { $0 = { _ in (200, #"{"access_token":"NEW","expires_in":3600}"#) } }
        let (service, logs) = service(secrets: secrets)
        let access = try await service.freshAccessToken(SpotifyCredentials(clientID: "id", clientSecret: "s"))
        #expect(access == "NEW")
        let request = try #require(sent().first)
        #expect(request.body == "grant_type=refresh_token&refresh_token=KEEP&client_id=id")
        #expect(request.headers["Authorization"] == "Basic " + Data("id:s".utf8).base64EncodedString())
        let stored = try #require(try secrets.value(SpotifyTokens.self, for: .spotifyTokens, profile: profile))
        #expect(stored == SpotifyTokens(accessToken: "NEW", refreshToken: "KEEP", expiresAt: start.addingTimeInterval(3600)))
        #expect(logs().allSatisfy { !$0.contains("NEW") && !$0.contains("KEEP") && !$0.contains("OLD") })
    }

    @Test func aRejectedRefreshTokenDisconnects() async throws {
        let secrets = try configured()
        try secrets.setValue(SpotifyTokens(accessToken: "OLD", refreshToken: "R", expiresAt: start),
                             for: .spotifyTokens, profile: profile)
        SpotifyStubProtocol.responder.withLock { $0 = { _ in (400, #"{"error":"invalid_grant"}"#) } }
        let (service, _) = service(secrets: secrets)
        await #expect(throws: SpotifyError.refreshRejected) { try await service.current(clientID: "id") }
        #expect(await !service.isConnected())
    }

    @Test func nothingPlayingFallsBackToTheRecentlyPlayedTrackAsPaused() async throws {
        let secrets = try configured()
        try secrets.setValue(SpotifyTokens(accessToken: "ACC", refreshToken: "R", expiresAt: start.addingTimeInterval(600)),
                             for: .spotifyTokens, profile: profile)
        SpotifyStubProtocol.responder.withLock { $0 = { request in
            if request.url == Spotify.nowPlayingURL { return (204, "") }
            return (200, #"{"items":[{"track":{"name":"Last","artists":[{"name":"Band"}],"album":{"name":"Rec","images":[{"url":"https://i/large"},{"url":"https://i/small"}]},"duration_ms":1000,"external_urls":{"spotify":"https://open.spotify.com/track/x"}}}]}"#)
        } }
        let (service, _) = service(secrets: secrets)
        let track = try #require(try await service.current(clientID: "id"))
        #expect(track == SpotifyNowPlaying(playing: false, track: "Last", artist: "Band", album: "Rec",
                                           coverURL: URL(string: "https://i/small"), durationMs: 1000, progressMs: 0,
                                           trackURL: URL(string: "https://open.spotify.com/track/x")))
        #expect(sent().map(\.url) == [Spotify.nowPlayingURL, Spotify.recentlyPlayedURL])
        #expect(sent().allSatisfy { $0.headers["Authorization"] == "Bearer ACC" })
    }

    @Test func notConnectedOrNotConfiguredIsNil() async throws {
        let (unconfigured, _) = service(secrets: InMemorySecretStore())
        #expect(try await unconfigured.current(clientID: "id") == nil)
        let (disconnected, _) = service(secrets: try configured())
        #expect(try await disconnected.current(clientID: "id") == nil)
        #expect(sent().isEmpty)
    }

    @Test func logoutDeletesTheTokens() async throws {
        let secrets = try configured()
        try secrets.setValue(SpotifyTokens(accessToken: "A", refreshToken: "R", expiresAt: start),
                             for: .spotifyTokens, profile: profile)
        let (service, _) = service(secrets: secrets)
        try await service.logout()
        #expect(try secrets.data(for: .spotifyTokens, profile: profile) == nil)
        #expect(try secrets.string(for: .spotifyClientSecret, profile: profile) == "the-client-secret")
    }

    @Test func errorLabelsNeverCarryOutsideText() {
        #expect(SpotifyService.label(.authorizationDenied("<script>")) == "authorizationDenied")
        #expect(SpotifyService.label(.tokenRequestFailed(status: 400, reason: "x")) == "tokenRequestFailed 400")
    }
}
