import Foundation
import Synchronization
import Testing
@testable import AletheIntegrations

/// Records what the session sends, in order.
private final class FakeDiscordClient: DiscordPresenceClient {
    enum Call: Equatable {
        case set(DiscordActivity)
        case clear
    }

    private let log = Mutex<[Call]>([])
    var calls: [Call] { log.withLock { $0 } }
    var sets: [DiscordActivity] { calls.compactMap { if case .set(let activity) = $0 { activity } else { nil } } }

    func setActivity(_ activity: DiscordActivity) async -> Bool {
        log.withLock { $0.append(.set(activity)) }
        return true
    }

    func clearActivity() async {
        log.withLock { $0.append(.clear) }
    }
}

@MainActor
@Suite struct DiscordPresenceSessionTests {
    private let launch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func eachViewHasItsUpstreamLabel() {
        #expect(DiscordPresenceView.dashboard.state == "Viewing the dashboard")
        #expect(DiscordPresenceView.terminals.state == "Managing terminals")
        #expect(DiscordPresenceView.orchestration.state == "Orchestrating AI agents")
    }

    @Test func activityPerViewCarriesTheLaunchTime() async {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch)
        for view in [DiscordPresenceView.dashboard, .terminals, .orchestration] {
            session.update(enabled: true, view: view)
        }
        await session.settle()
        #expect(client.sets == [
            DiscordActivity(details: "Working with Alethe", state: "Viewing the dashboard", startedAt: 1_700_000_000),
            DiscordActivity(details: "Working with Alethe", state: "Managing terminals", startedAt: 1_700_000_000),
            DiscordActivity(details: "Working with Alethe", state: "Orchestrating AI agents", startedAt: 1_700_000_000),
        ])
        await session.stop()
    }

    @Test func anUnchangedViewSendsNothingNew() async {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch)
        session.update(enabled: true, view: .terminals)
        session.update(enabled: true, view: .terminals)
        await session.settle()
        #expect(client.calls.count == 1)
        await session.stop()
    }

    @Test func offNeverTalksToDiscord() async {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch)
        session.update(enabled: false, view: .dashboard)
        session.update(enabled: false, view: .terminals)
        await session.stop()
        #expect(client.calls.isEmpty)
    }

    @Test func turningOffClearsTheActivity() async {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch)
        session.update(enabled: true, view: .dashboard)
        session.update(enabled: false, view: .dashboard)
        await session.settle()
        #expect(client.calls == [.set(session.activity(for: .dashboard)), .clear])
        #expect(session.current == nil)
        // Back on: sent again even though the view did not change.
        session.update(enabled: true, view: .dashboard)
        await session.settle()
        #expect(client.calls.last == .set(session.activity(for: .dashboard)))
        await session.stop()
    }

    @Test func stoppingClearsAndIgnoresLaterUpdates() async {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch)
        session.update(enabled: true, view: .orchestration)
        await session.stop()
        #expect(client.calls.last == .clear)
        let count = client.calls.count
        session.update(enabled: true, view: .terminals)
        await session.settle()
        #expect(client.calls.count == count)
    }

    @Test func refreshesWhileOnAndStopsWhenOff() async throws {
        let client = FakeDiscordClient()
        let session = DiscordPresenceSession(client: client, startedAt: launch, refreshInterval: .milliseconds(20))
        session.update(enabled: true, view: .terminals)
        try await Task.sleep(for: .milliseconds(200))
        await session.settle()
        #expect(client.sets.count >= 3)
        #expect(Set(client.sets) == [session.activity(for: .terminals)])
        session.update(enabled: false, view: .terminals)
        await session.settle()
        let count = client.calls.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.calls.count == count)
        #expect(client.calls.last == .clear)
        await session.stop()
    }
}
