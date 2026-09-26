import Foundation
import Testing
@testable import AletheRemote

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private let offlineResolver = RemoteHostResolver(lanAddress: { "192.168.1.20" }, tailscaleAddress: { nil })

private func makeHub(clock: TestClock = TestClock(), resolver: RemoteHostResolver = offlineResolver) -> RemoteHub {
    RemoteHub(resolver: resolver, now: { clock.now })
}

/// A running hub with its pairing window open.
private func openHub(clock: TestClock = TestClock()) async -> RemoteHub {
    let hub = makeHub(clock: clock)
    await hub.beginRun()
    await hub.openPairingWindow()
    return hub
}

/// Upstream `remote/state.rs` tests.
struct RemoteHubGoldenTests {
    @Test func publishDoesNotBuildPayloadWithoutSubscribers() async {
        let hub = makeHub()
        let built = Flag()

        await hub.publish(terminalID: "pty-1") {
            built.set()
            return #"{"type":"test"}"#
        }

        #expect(!built.isSet)
    }

    @Test func inactiveHubReportsNoConnectedDevices() async {
        let hub = makeHub()
        #expect(await hub.connectedDeviceCount() == 0)
    }

    @Test func pairingIsClosedUntilAWindowIsOpened() async {
        let hub = makeHub()

        #expect(await hub.pairingRemaining == 0)
        #expect(await hub.pairingURL == nil)
        await #expect(throws: RemotePairingError.windowClosed) {
            try await hub.pair(token: "anything", name: "Phone", address: "127.0.0.1:1")
        }
    }

    @Test func pairingRejectsAnUnknownTokenWhileOpen() async {
        let hub = await openHub()

        await #expect(throws: RemotePairingError.invalidToken) {
            try await hub.pair(token: "wrong-token", name: "Phone", address: "127.0.0.1:1")
        }
    }

    @Test func pairingIssuesASessionTokenAndClosesTheWindow() async throws {
        let hub = await openHub()
        let token = await hub.pairingToken

        let pairing = try await hub.pair(token: token, name: "Phone", address: "127.0.0.1:1")

        #expect(await hub.sessionID(for: pairing.sessionToken) == pairing.deviceID)
        #expect(await hub.pairingRemaining == 0)
        #expect(await hub.sessionID(for: "not-a-session") == nil)
    }

    @Test func pairingHonoursTheDeviceLimit() async throws {
        let hub = await openHub()
        _ = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        await hub.openPairingWindow()
        let token = await hub.pairingToken

        await #expect(throws: RemotePairingError.deviceLimitReached) {
            try await hub.pair(token: token, name: "Tablet", address: "127.0.0.1:2")
        }
    }

    @Test func revokingADeviceInvalidatesItsSessionToken() async throws {
        let hub = await openHub()
        let pairing = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        await hub.revokeDevice(pairing.deviceID)

        #expect(await hub.sessionID(for: pairing.sessionToken) == nil)
    }

    @Test func repeatedFailuresLockAnAddressOut() async {
        let hub = makeHub()
        let address = "192.168.0.44:5100"

        for _ in 0..<RemoteLimits.authFailureLimit {
            await hub.recordAuthFailure(address)
        }

        #expect(await hub.authBlocked(address))
        await hub.clearAuthFailures(address)
        #expect(await !hub.authBlocked(address))
    }

    @Test func qrIsCachedByPairingURL() throws {
        let qr = RemotePairingQR()
        let url = "http://127.0.0.1:9340/?pair=test"

        let first = try #require(qr.image(for: url))
        let second = try #require(qr.image(for: url))

        #expect(first === second)
        #expect(qr.cachedURL == url)
    }

    @Test func tailscaleModeWithoutADetectedIPFailsClosedToAnUnbindableHost() async {
        let hub = makeHub()
        await hub.setReachMode(.tailscale)

        await hub.refreshHost()

        // Never the LAN address or a wildcard: nothing can bind the empty host.
        #expect(await !RemoteHost.isBindableAddress(hub.host))
    }

    @Test func lanModeStillResolvesARealBindableHost() async {
        let hub = makeHub(resolver: .system)

        await hub.refreshHost()

        #expect(await RemoteHost.isBindableAddress(hub.host))
    }

    @Test func messageRateLimitBlocksABurstPastTheCap() async {
        let hub = makeHub()

        var allowed = 0
        for _ in 0..<(RemoteLimits.messageRateLimit + 5) {
            if await hub.allowMessage(1) { allowed += 1 }
        }

        #expect(allowed == RemoteLimits.messageRateLimit)
    }

    @Test func messageRateLimitIsTrackedPerSession() async {
        let hub = makeHub()

        for _ in 0..<RemoteLimits.messageRateLimit {
            #expect(await hub.allowMessage(1))
        }
        #expect(await !hub.allowMessage(1))

        #expect(await hub.allowMessage(2))
    }

    @Test func idleExpiredOnlyTripsPastAPositiveThreshold() {
        #expect(!RemoteHub.idleExpired(now: 100, lastActive: 100, threshold: 0))
        #expect(!RemoteHub.idleExpired(now: 100, lastActive: 99, threshold: 10))
        #expect(RemoteHub.idleExpired(now: 110, lastActive: 100, threshold: 10))
        #expect(RemoteHub.idleExpired(now: 200, lastActive: 100, threshold: 10))
    }

    @Test func hubIsIdleOnlyOnceTheThresholdElapsesWithNobodyConnected() async {
        let hub = makeHub()

        #expect(await !hub.isIdle(threshold: 0))
        #expect(await !hub.isIdle(threshold: 3600))
    }
}

struct RemoteHubTests {
    @Test func lockoutExpiresAfterFiveMinutes() async {
        let clock = TestClock()
        let hub = makeHub(clock: clock)
        let address = "10.0.0.8:6000"
        for _ in 0..<RemoteLimits.authFailureLimit {
            await hub.recordAuthFailure(address)
        }
        #expect(await hub.authBlocked("10.0.0.8:6001"))

        clock.advance(RemoteLimits.authLockout - 1)
        #expect(await hub.authBlocked(address))
        clock.advance(2)
        #expect(await !hub.authBlocked(address))

        // A fresh window: one more failure does not lock again.
        await hub.recordAuthFailure(address)
        #expect(await !hub.authBlocked(address))
    }

    @Test func failuresSpreadBeyondTheWindowDoNotLock() async {
        let clock = TestClock()
        let hub = makeHub(clock: clock)
        for _ in 0..<(RemoteLimits.authFailureLimit - 1) {
            await hub.recordAuthFailure("10.0.0.9:1")
        }
        clock.advance(RemoteLimits.authFailureWindow + 1)
        await hub.recordAuthFailure("10.0.0.9:1")
        #expect(await !hub.authBlocked("10.0.0.9:1"))
    }

    @Test func aRevokedDevicesSubscriptionIsDropped() async throws {
        let hub = await openHub()
        let pairing = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")
        let stream = try #require(await hub.attach(pairing.deviceID))
        await hub.setSubscription(pairing.deviceID, terminalID: "tab-1")
        #expect(await hub.publish(terminalID: "tab-1", payload: { "one" }) == 1)

        await hub.revokeDevice(pairing.deviceID)

        let built = Flag()
        #expect(await hub.publish(terminalID: "tab-1", payload: { built.set(); return "two" }) == 0)
        #expect(!built.isSet)
        var received: [String] = []
        for await frame in stream { received.append(frame) }
        #expect(received == ["one"])
    }

    @Test func publishReachesOnlyTheSubscribedTerminal() async throws {
        let hub = await openHub()
        let pairing = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")
        let stream = try #require(await hub.attach(pairing.deviceID))
        await hub.setSubscription(pairing.deviceID, terminalID: "tab-1")

        await hub.publish(.data(terminalID: "tab-2", text: "other"))
        await hub.publish(.data(terminalID: "tab-1", text: "hello"))
        await hub.detach(pairing.deviceID)

        var received: [String] = []
        for await frame in stream { received.append(frame) }
        #expect(received.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(received[0].utf8)) as? [String: String]
        #expect(object == ["type": "pty_output", "ptyId": "tab-1", "text": "hello"])
        #expect(await hub.subscription(pairing.deviceID) == nil)
    }

    @Test func aNewerSocketReplacesTheOlderOne() async throws {
        let hub = await openHub()
        let pairing = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")
        let first = try #require(await hub.attach(pairing.deviceID))
        _ = try #require(await hub.attach(pairing.deviceID))

        var frames = 0
        for await _ in first { frames += 1 }
        #expect(frames == 0)
        #expect(await hub.info().onlineDevices == 1)
    }

    @Test func sessionsExpire() async throws {
        let clock = TestClock()
        let hub = await openHub(clock: clock)
        await hub.setSessionExpiry(0)
        #expect(await hub.sessionExpiry == RemoteLimits.sessionExpiryRange.lowerBound)
        let pairing = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        clock.advance(RemoteLimits.sessionExpiryRange.lowerBound + 1)

        #expect(await !hub.sessionAlive(pairing.deviceID))
        #expect(await hub.sessionID(for: pairing.sessionToken) == nil)
        #expect(await hub.connectedDeviceCount() == 0)
    }

    @Test func pairingWindowClosesAfterTwoMinutesAndRegeneratesItsToken() async {
        let clock = TestClock()
        let hub = await openHub(clock: clock)
        await hub.setHTTPPort(9340)
        let token = await hub.pairingToken
        #expect(token.count == RemoteLimits.pairingTokenLength)
        #expect(await hub.pairingURL == "http://:9340/?pair=\(token)")

        clock.advance(RemoteLimits.pairingWindow)
        #expect(await hub.pairingURL == nil)

        await hub.closePairingWindow()
        #expect(await hub.pairingToken != token)
    }

    @Test func pairingTruncatesTheNameAndIssuesAFortyCharacterToken() async throws {
        let hub = await openHub()
        let pairing = try await hub.pair(token: await hub.pairingToken, name: String(repeating: "n", count: 80), address: "127.0.0.1:1")
        #expect(pairing.sessionToken.count == RemoteLimits.sessionTokenLength)
        #expect(await hub.deviceName(pairing.deviceID).count == RemoteLimits.maxDeviceName)
    }

    @Test func preferencesAreClamped() async {
        let hub = makeHub()
        await hub.setMaxDevices(9)
        #expect(await hub.maxDevices == 4)
        await hub.setMaxDevices(0)
        #expect(await hub.maxDevices == 1)
        await hub.setSessionExpiry(100 * 3600)
        #expect(await hub.sessionExpiry == 24 * 3600)
        #expect(await hub.setReachMode(.tailscale))
        #expect(await !hub.setReachMode(.tailscale))
    }

    @Test func connectionCapHolds() async {
        let hub = makeHub()
        for _ in 0..<RemoteLimits.maxConnections {
            #expect(await hub.tryAcquireConnection())
        }
        #expect(await !hub.tryAcquireConnection())
        await hub.releaseConnection()
        #expect(await hub.tryAcquireConnection())
    }

    @Test func stopRevokesEveryDeviceAndBumpsTheGeneration() async throws {
        let hub = makeHub()
        let generation = try #require(await hub.start())
        #expect(await hub.start() == nil)
        #expect(await hub.host == "192.168.1.20")
        await hub.openPairingWindow()
        _ = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        await hub.stop()

        #expect(await !hub.isActive(generation: generation))
        #expect(await hub.info().connectedDevices == 0)
        #expect(await hub.pairingRemaining == 0)
    }

    @Test func idleOnlyAfterTheThresholdWithNobodyPaired() async throws {
        let clock = TestClock()
        let hub = makeHub(clock: clock)
        _ = await hub.start()
        clock.advance(RemoteLimits.idleDisable)
        #expect(await hub.isIdle())

        await hub.touchActivity()
        await hub.setSessionExpiry(RemoteLimits.sessionExpiryRange.upperBound)
        await hub.openPairingWindow()
        _ = try await hub.pair(token: await hub.pairingToken, name: "Phone", address: "127.0.0.1:1")
        clock.advance(RemoteLimits.idleDisable)
        #expect(await !hub.isIdle())
    }

    @Test func eventsReachTheConsumer() async {
        let hub = makeHub()
        hub.emit(.startFailed)
        var iterator = hub.events.makeAsyncIterator()
        #expect(await iterator.next() == .startFailed)
    }
}
