import Foundation
import Testing
@testable import AletheIntegrations

/// A Spotify stand-in: counts requests and answers with what the test set.
private actor StubSource: NowPlayingSource {
    var connected: Bool
    var track: SpotifyNowPlaying?
    var failure: SpotifyError?
    private(set) var currentCalls = 0
    private(set) var logins = 0
    private(set) var logouts = 0
    private(set) var clientIDs: [String?] = []

    init(connected: Bool, track: SpotifyNowPlaying? = nil) {
        self.connected = connected
        self.track = track
    }

    func set(track: SpotifyNowPlaying?) { self.track = track }
    func set(failure: SpotifyError?) { self.failure = failure }

    func isConnected() async -> Bool { connected }

    func login(clientID: String?) async throws(SpotifyError) {
        logins += 1
        clientIDs.append(clientID)
        if let failure { throw failure }
        connected = true
    }

    func logout() async throws(SpotifyError) {
        logouts += 1
        connected = false
    }

    func current(clientID: String?) async throws(SpotifyError) -> SpotifyNowPlaying? {
        currentCalls += 1
        if let failure { throw failure }
        return track
    }
}

private func track(_ name: String, playing: Bool = true, progressMs: Int = 1_000) -> SpotifyNowPlaying {
    SpotifyNowPlaying(playing: playing, track: name, artist: "An Artist", album: "An Album", coverURL: nil,
                      durationMs: 200_000, progressMs: progressMs,
                      trackURL: URL(string: "https://open.spotify.com/track/\(name)"))
}

private func temporaryStore() -> NowPlayingLastTrackStore {
    NowPlayingLastTrackStore(url: FileManager.default.temporaryDirectory
        .appending(path: "now-playing-\(UUID().uuidString)").appending(path: NowPlayingLastTrackStore.fileName))
}

/// Polls `condition` on the main actor for up to `timeout` seconds.
@MainActor
private func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@MainActor
struct NowPlayingModelTests {
    @Test func pollsOnlyWhileAViewIsVisible() async {
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .milliseconds(10))
        #expect(!model.isPolling)
        model.viewAppeared()
        #expect(await eventually { await source.currentCalls >= 2 })
        #expect(model.isPolling)
        #expect(model.current?.track == "one")

        model.viewDisappeared()
        #expect(!model.isPolling)
        try? await Task.sleep(for: .milliseconds(30))
        let stopped = await source.currentCalls
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await source.currentCalls == stopped)
    }

    @Test func pollingStopsWhenTheAppIsInactiveAndResumes() async {
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .milliseconds(10))
        model.viewAppeared()
        #expect(await eventually { model.isPolling })
        model.setAppActive(false)
        #expect(!model.isPolling)
        try? await Task.sleep(for: .milliseconds(30))
        let stopped = await source.currentCalls
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await source.currentCalls == stopped)
        model.setAppActive(true)
        #expect(model.isPolling)
        #expect(await eventually { await source.currentCalls > stopped })
    }

    @Test func twoViewsKeepPollingUntilBothDisappear() async {
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .milliseconds(10))
        model.viewAppeared()
        model.viewAppeared()
        #expect(await eventually { model.isPolling })
        model.viewDisappeared()
        #expect(model.isPolling)
        model.viewDisappeared()
        #expect(!model.isPolling)
    }

    @Test func nothingPollsWhenNotConnected() async {
        let source = StubSource(connected: false, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .milliseconds(10))
        model.viewAppeared()
        #expect(await eventually { model.connected == false })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!model.isPolling)
        #expect(await source.currentCalls == 0)
    }

    @Test func lastTrackIsSavedAndRestoredPaused() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let source = StubSource(connected: true, track: track("kept", playing: true))
        let model = NowPlayingModel(source: source, lastTrack: store, interval: .seconds(60))
        model.viewAppeared()
        #expect(await eventually { model.current?.track == "kept" })
        #expect(await eventually { await store.load() != nil })

        // A relaunch: a new model over the same file, before any fetch.
        let relaunched = NowPlayingModel(source: StubSource(connected: false), lastTrack: store)
        await relaunched.restoreLastTrack()
        let restored = try #require(relaunched.current)
        #expect(restored.track == "kept")
        #expect(!restored.playing)
        #expect(relaunched.progressMs(at: Date().addingTimeInterval(30)) == restored.progressMs)
    }

    @Test func restoreDoesNotReplaceAFetchedTrack() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        await store.save(track("old"))
        let model = NowPlayingModel(source: StubSource(connected: true, track: track("new")), lastTrack: store,
                                    interval: .seconds(60))
        model.viewAppeared()
        #expect(await eventually { model.current?.track == "new" })
        await model.restoreLastTrack()
        #expect(model.current?.track == "new")
    }

    @Test func nothingPlayingKeepsTheTrackPaused() async {
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .seconds(60))
        model.viewAppeared()
        #expect(await eventually { model.current?.playing == true })
        await source.set(track: nil)
        await model.refresh()
        #expect(model.current?.track == "one")
        #expect(model.current?.playing == false)
    }

    @Test func rejectedRefreshTokenDisconnectsAndStopsPolling() async {
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .milliseconds(10))
        model.viewAppeared()
        #expect(await eventually { model.isPolling })
        await source.set(failure: .refreshRejected)
        #expect(await eventually { model.connected == false })
        #expect(!model.isPolling)
        #expect(model.error == .refreshRejected)
    }

    @Test func connectLogsInWithTheClientIDAndFetches() async {
        let source = StubSource(connected: false, track: track("after login"))
        let model = NowPlayingModel(source: source, lastTrack: nil, interval: .seconds(60))
        model.clientID = { "client-id" }
        model.viewAppeared()
        #expect(await eventually { model.connected == false })
        await model.connect()
        #expect(model.connected == true)
        #expect(await source.clientIDs == ["client-id"])
        #expect(await eventually { model.current?.track == "after login" })
        #expect(model.isPolling)
    }

    @Test func failedConnectReportsTheError() async {
        let source = StubSource(connected: false)
        await source.set(failure: .missingCredentials)
        let model = NowPlayingModel(source: source, lastTrack: nil)
        await model.connect()
        #expect(model.connected == false)
        #expect(model.error == .missingCredentials)
        #expect(!model.connecting)
    }

    @Test func disconnectClearsTheTrackAndTheKeptCopy() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let source = StubSource(connected: true, track: track("one"))
        let model = NowPlayingModel(source: source, lastTrack: store, interval: .seconds(60))
        model.viewAppeared()
        #expect(await eventually { await store.load() != nil })
        await model.disconnect()
        #expect(model.connected == false)
        #expect(model.current == nil)
        #expect(!model.isPolling)
        #expect(await source.logouts == 1)
        #expect(await store.load() == nil)
    }

    @Test func progressAdvancesWhilePlayingUpToTheDuration() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let model = NowPlayingModel(source: StubSource(connected: true, track: track("one", progressMs: 10_000)),
                                    lastTrack: nil, interval: .seconds(60), now: { start })
        model.viewAppeared()
        #expect(await eventually { model.current != nil })
        #expect(model.progressMs(at: start.addingTimeInterval(5)) == 15_000)
        #expect(model.progressMs(at: start.addingTimeInterval(10_000)) == 200_000)
    }
}
