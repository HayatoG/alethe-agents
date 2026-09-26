import Foundation
import Testing
import AletheAgents
@testable import AletheOrchestrator

// P6-17: the board header's quota warnings (upstream `useOrchestratorQuotaWarnings`) and the usage
// feed that pushes fitness into the core while a board is open.

private func usage(_ agent: AgentKind, _ percent: Double, rateLimited: Bool = false, resetsAt: Date? = nil) -> ProviderUsage {
    ProviderUsage(agent: agent, status: .ready, windows: [UsageWindow(label: "5h", usedPercent: percent, resetsAt: resetsAt)],
                  rateLimited: rateLimited)
}

/// What the feed read, pushed and published, shared with its closures.
private actor Recorder {
    var reads = 0
    var pushed: [String] = []
    var published: [[QuotaWarning]] = []
    var usages: [ProviderUsage] = []

    func set(_ usages: [ProviderUsage]) { self.usages = usages }
    func read() -> [ProviderUsage] { reads += 1; return usages }
    func push(_ agent: String) { pushed.append(agent) }
    func publish(_ warnings: [QuotaWarning]) { published.append(warnings) }
}

private func feed(_ recorder: Recorder, interval: Duration = .milliseconds(20)) -> FitnessFeed {
    FitnessFeed(interval: interval,
                read: { await recorder.read() },
                push: { agent, _ in await recorder.push(agent) },
                publish: { await recorder.publish($0) })
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<200 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite struct QuotaWarningTests {
    @Test func warnsAtTheHeadroomThresholdNotBelow() {
        #expect(QuotaWarning(agent: "codex", fitness: AgentFitness(worst: "5h", used: 79)) == nil)
        let warning = QuotaWarning(agent: "codex", fitness: AgentFitness(worst: "5h", used: 80))
        #expect(warning?.used == 80)
        #expect(QuotaWarning(agent: "claude", fitness: AgentFitness(worst: "week", used: 100)) != nil)
    }

    @Test func aRateLimitedAgentWarnsAtAnyPercentage() {
        let warning = QuotaWarning(agent: "codex", fitness: AgentFitness(worst: "5h", used: 10, rateLimited: true))
        #expect(warning?.rateLimited == true)
        #expect(warning?.used == 10)
    }

    @Test func warningsKeepOnlyStrainedAgentsSortedByName() {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        let warnings = QuotaWarning.warnings([
            "codex": AgentFitness(worst: "week", used: 91, resetsAt: reset),
            "claude": AgentFitness(worst: "5h", used: 85),
            "opencode": AgentFitness(worst: "5h", used: 40),
        ])
        #expect(warnings.map(\.agent) == ["claude", "codex"])
        #expect(warnings.last?.resetsAt == reset)
    }

    @Test func countdownMatchesUpstreamFormatReset() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(QuotaWarning.countdown(to: now.addingTimeInterval(2 * 3600 + 5 * 60 + 30), now: now) == "2h5m")
        #expect(QuotaWarning.countdown(to: now.addingTimeInterval(59 * 60 + 59), now: now) == "59m")
        #expect(QuotaWarning.countdown(to: now.addingTimeInterval(30), now: now) == "0m")
        #expect(QuotaWarning.countdown(to: now, now: now) == nil)
        #expect(QuotaWarning.countdown(to: now.addingTimeInterval(-60), now: now) == nil)
    }
}

@Suite struct FitnessFeedTests {
    @Test func readsRightAwayPushesFitnessAndPublishesWarnings() async {
        let recorder = Recorder()
        await recorder.set([usage(.claude, 30), usage(.codex, 92),
                            ProviderUsage(agent: .antigravity, status: .noAuth)])
        let feed = feed(recorder, interval: .seconds(60))
        let board = UUID()
        await feed.open(board)
        await waitUntil { await !recorder.published.isEmpty }
        #expect(await recorder.pushed == ["claude", "codex"], "a reading without windows is not pushed")
        #expect(await recorder.published.first?.map(\.agent) == ["codex"])
        await feed.close(UUID())
        #expect(await feed.isRunning, "closing a board that never opened leaves the others")
        await feed.close(board)
    }

    @Test func aFailedReadKeepsTheLastWarning() async {
        let recorder = Recorder()
        await recorder.set([usage(.codex, 95)])
        let feed = feed(recorder)
        let board = UUID()
        await feed.open(board)
        await waitUntil { await !recorder.published.isEmpty }
        await recorder.set([ProviderUsage(agent: .codex, status: .unavailable("network"))])
        let before = await recorder.reads
        await waitUntil { await recorder.reads > before + 1 }
        #expect(await recorder.published.last?.map(\.agent) == ["codex"])
        await feed.close(board)
    }

    @Test func theFeedStopsWhenTheLastBoardCloses() async throws {
        let recorder = Recorder()
        await recorder.set([usage(.codex, 50)])
        let feed = feed(recorder)
        let first = UUID(), second = UUID()
        await feed.open(first)
        await feed.open(second)
        #expect(await feed.openBoards == 2)
        await waitUntil { await recorder.reads >= 2 }

        await feed.close(first)
        #expect(await feed.isRunning, "another board is still open")
        let whileOpen = await recorder.reads
        await waitUntil { await recorder.reads > whileOpen }
        #expect(await recorder.reads > whileOpen, "the remaining board keeps the feed reading")

        await feed.close(second)
        #expect(await !feed.isRunning)
        // A tick already under way may finish; after that nothing more is read.
        try await Task.sleep(for: .milliseconds(50))
        let stopped = await recorder.reads
        try await Task.sleep(for: .milliseconds(150))
        #expect(await recorder.reads == stopped, "no reads after the last board closed")

        await feed.open(first)
        #expect(await feed.isRunning, "opening a board again restarts it")
        await feed.close(first)
    }
}
