import Foundation
import Testing
import AletheAgents
import AletheIntegrations
@testable import AletheOrchestrator

// Upstream `src/lib/agentFitness.test.ts`, fed through the P3-13 readers' own parsers.

private func claudeUsage(_ fiveHour: Double, _ sevenDay: Double, _ opus: Double,
                         resets: (String, String, String) = ("", "", "")) throws -> ProviderUsage {
    let body: [String: Any] = [
        "five_hour": ["utilization": fiveHour, "resets_at": resets.0],
        "seven_day": ["utilization": sevenDay, "resets_at": resets.1],
        "seven_day_opus": ["utilization": opus, "resets_at": resets.2],
    ]
    return try #require(AIUsage.parseClaude(try JSONSerialization.data(withJSONObject: body)))
}

private func codexUsage(_ primary: Double, _ secondary: Double, plan: String? = "plus",
                        rateLimited: Bool = false, secondaryResetsAt: Double? = nil) throws -> ProviderUsage {
    var secondaryWindow: [String: Any] = ["usedPercent": secondary, "windowDurationMins": 10080]
    if let secondaryResetsAt { secondaryWindow["resetsAt"] = secondaryResetsAt }
    let reached: Any = rateLimited ? "primary" : NSNull()
    var limits: [String: Any] = [
        "primary": ["usedPercent": primary, "windowDurationMins": 300],
        "secondary": secondaryWindow,
        "rateLimitReachedType": reached,
    ]
    if let plan { limits["planType"] = plan }
    return try #require(AIUsage.parseCodex(["rateLimits": limits]))
}

@Suite struct AgentFitnessTests {
    // Upstream "reports the window closest to its ceiling, not the five-hour one".
    @Test func reportsTheWindowClosestToItsCeiling() throws {
        let fitness = try #require(AgentFitness(try codexUsage(22, 60)))
        #expect(fitness.worst == "week")
        #expect(fitness.used == 60)
    }

    // Upstream "keeps the two vendors comparable when their five-hour windows look tied".
    @Test func keepsTheTwoVendorsComparable() throws {
        let claude = try #require(AgentFitness(try claudeUsage(20, 19, 0)))
        let codex = try #require(AgentFitness(try codexUsage(22, 60)))
        #expect(claude.used < codex.used)
    }

    // Upstream "carries the detected codex plan and drops it when absent".
    @Test func carriesTheCodexPlanAndDropsItWhenAbsent() throws {
        #expect(AgentFitness(try codexUsage(1, 1, plan: "plus"))?.plan == "plus")
        #expect(AgentFitness(try codexUsage(1, 1, plan: ""))?.plan == nil)
        #expect(AgentFitness(try codexUsage(1, 1, plan: nil))?.plan == nil)
    }

    // Upstream "carries the reset time of the worst window" (real timestamps: the reader parses them).
    @Test func carriesTheResetTimeOfTheWorstWindow() throws {
        let fitness = try #require(AgentFitness(try claudeUsage(
            10, 90, 0, resets: ("2026-09-25T10:00:00Z", "2026-09-30T08:00:00Z", ""))))
        #expect(fitness.worst == "week")
        #expect(fitness.resetsAt == ISO8601DateFormatter().date(from: "2026-09-30T08:00:00Z"))
        #expect(fitness.json.objectValue?["resetsAt"] == "2026-09-30T08:00:00.000Z")
    }

    @Test func codexResetsAndRateLimitCarryOver() throws {
        let fitness = try #require(AgentFitness(try codexUsage(10, 5, rateLimited: true, secondaryResetsAt: 0)))
        #expect(fitness.worst == "5h")
        #expect(fitness.rateLimited)
        #expect(fitness.resetsAt == nil, "the primary window carried no reset")
    }

    @Test func claudeIsNeverReportedRateLimitedLikeUpstream() throws {
        let fitness = try #require(AgentFitness(try claudeUsage(100, 3, 0)))
        #expect(fitness.used == 100)
        #expect(!fitness.rateLimited)
        #expect(fitness.isStrained, "a spent window is strained all the same")
    }

    @Test func theOpusWindowGetsUpstreamsName() throws {
        #expect(AgentFitness(try claudeUsage(1, 2, 70))?.worst == "opus")
    }

    @Test func aTieKeepsTheEarlierWindow() throws {
        #expect(AgentFitness(try codexUsage(40, 40))?.worst == "5h")
    }

    @Test func aReadingWithoutWindowsHasNoFitness() {
        #expect(AgentFitness(ProviderUsage(agent: .claude, status: .noAuth)) == nil)
        #expect(AgentFitness(ProviderUsage(agent: .codex, status: .ready)) == nil)
    }

    @Test func usedIsRoundedLikeMathRound() {
        let usage = ProviderUsage(agent: .codex, status: .ready, windows: [
            UsageWindow(label: "5h", usedPercent: 79.5, resetsAt: nil),
        ])
        #expect(AgentFitness(usage)?.used == 80)
    }

    @Test func theSnapshotKeepsUpstreamsKeysAndOrder() {
        let withPlan = AgentFitness(worst: "week", used: 60, plan: "plus")
        #expect(withPlan.json.objectValue?.keys == ["worst", "used", "resetsAt", "plan", "rateLimited"])
        #expect(withPlan.json.compactRendered() == #"{"worst":"week","used":60,"resetsAt":null,"plan":"plus","rateLimited":false}"#)
        #expect(AgentFitness(worst: "5h", used: 1).json.objectValue?.keys == ["worst", "used", "resetsAt", "rateLimited"])
    }
}

@Suite struct FitnessRoutingTests {
    @Test func noReadingsMeansNoBlock() {
        let routing = FitnessRouting([:])
        #expect(routing.block == nil)
        #expect(routing.headroom == nil)
        #expect(routing.routingNote(requested: "codex") == nil)
    }

    @Test func agentsAreSortedAndATieGoesToTheFirstByName() {
        let routing = FitnessRouting([
            "codex": AgentFitness(worst: "5h", used: 30),
            "claude": AgentFitness(worst: "5h", used: 30),
        ])
        #expect(routing.headroom == "claude")
        #expect(routing.block?.objectValue?.keys == ["claude", "codex", "headroom"])
    }

    @Test func theThresholdIsInclusive() {
        #expect(AgentFitness(worst: "5h", used: 80).isStrained)
        #expect(!AgentFitness(worst: "5h", used: 79).isStrained)
        #expect(AgentFitness(worst: "5h", used: 0, rateLimited: true).isStrained)
    }

    @Test func aRateLimitedRequestSaysSo() {
        let routing = FitnessRouting([
            "claude": AgentFitness(worst: "week", used: 12),
            "codex": AgentFitness(worst: "5h", used: 10, rateLimited: true),
        ])
        let hint = routing.headroomHint(requested: "codex")?.objectValue
        #expect(hint?["agent"] == "claude")
        #expect(hint?["bothStrained"] == false)
        #expect(hint?["reason"] == "codex is rate-limited right now; claude is at 12%")
    }

    @Test func noHintWhenTheStrainedSideIsAlsoTheRoomiest() {
        let routing = FitnessRouting(["codex": AgentFitness(worst: "5h", used: 95)])
        #expect(routing.headroomHint(requested: "codex") == nil)
    }

    @Test func aStrainedHintQuotesItsWindow() {
        let routing = FitnessRouting([
            "claude": AgentFitness(worst: "week", used: 12),
            "codex": AgentFitness(worst: "week", used: 91),
        ])
        #expect(routing.headroomHint(requested: "codex")?.objectValue?["reason"] == "codex is at 91% of its week window; claude is at 12%")
        let note = routing.routingNote(requested: "claude")?.objectValue
        #expect(note?.keys == ["verdict", "agent", "window", "used"])
        #expect(note?["verdict"] == "chosen")
        #expect(note?["window"] == "week")
        #expect(note?["used"] == .double(91))
    }
}
