import Foundation
import Testing
import AletheIntegrations
@testable import AletheOrchestrator

// Ported from upstream `src/lib/orchestratorRuns.test.ts` (25 cases).

@Suite struct AggregateAgentSpendTests {
    @Test func groupsReportedSessionSpendByWorkerProvider() {
        let spend = AgentSpend.aggregate([
            boardJob("claude-1", run: "run-a", agent: "claude", tokens: ["total": ["totalTokens": 1200]], costUSD: 0.012),
            boardJob("claude-2", run: "run-a", agent: "claude", tokens: ["total": ["totalTokens": 800]], costUSD: 0.008),
            boardJob("codex-1", run: "run-a", agent: "codex", tokens: ["total": ["totalTokens": 500]], costUSD: nil),
        ])
        #expect(spend.map(\.agent) == ["claude", "codex"])
        #expect(spend[0].totalTokens == 2000)
        #expect(abs(spend[0].costUSD - 0.02) < 1e-12)
        #expect(spend[0].pricedWorkers == 2)
        #expect(spend[0].unpricedWorkers == 0)
        #expect(spend[1] == AgentSpend(agent: "codex", totalTokens: 500, costUSD: 0, pricedWorkers: 0, unpricedWorkers: 1))
    }

    @Test func ignoresWorkersThatHaveNotReportedUsageYet() {
        #expect(AgentSpend.aggregate([boardJob("empty", run: "run-a")]) == [])
    }
}

@Suite struct GroupRunsTests {
    @Test func groupsJobsByRunIDKeepingFirstSeenOrder() {
        let runs = BoardRun.group([
            boardJob("job-01", run: "run-b"),
            boardJob("job-02", run: "run-a"),
            boardJob("job-03", run: "run-b"),
        ])
        #expect(runs.map(\.id) == ["run-b", "run-a"])
        #expect(runs[0].jobs.map(\.id) == ["job-01", "job-03"])
    }

    @Test func fallsBackToTheRunIDWhenNoWorkerCarriesALabel() {
        let runs = BoardRun.group([boardJob("job-01", run: "run-a")])
        #expect(runs.first?.label == "run-a")
    }

    @Test func takesTheLabelFromTheFirstWorkerThatHasOne() {
        let runs = BoardRun.group([
            boardJob("job-01", run: "run-a", label: "   "),
            boardJob("job-02", run: "run-a", label: " refactor pty "),
        ])
        #expect(runs.first?.label == "refactor pty")
    }

    @Test func reportsTheWorstStateAmongTheWorkersOfARun() throws {
        let run = try #require(BoardRun.group([
            boardJob("job-01", run: "run-a", status: .done),
            boardJob("job-02", run: "run-a", status: .running),
            boardJob("job-03", run: "run-a", status: .failed),
        ]).first)
        #expect(run.state == .failed)
        #expect(run.counts == counts(running: 1, failed: 1, finished: 1))
    }

    @Test func ranksRunningAboveQueuedAndQueuedAboveFinished() {
        #expect(RunCounts(jobs: [boardJob("a", run: "r", status: .queued)]).worstState == .queued)
        #expect(RunCounts(jobs: [
            boardJob("a", run: "r", status: .queued),
            boardJob("b", run: "r", status: .running),
        ]).worstState == .running)
        #expect(RunCounts(jobs: [
            boardJob("a", run: "r", status: .cancelled),
            boardJob("b", run: "r", status: .released),
        ]).worstState == .finished)
    }

    @Test func keepsInterruptedWorkInItsOwnLaneAboveTheLiveWorkers() throws {
        let run = try #require(BoardRun.group([
            boardJob("job-01", run: "run-a", status: .running),
            boardJob("job-02", run: "run-a", status: .interrupted),
        ]).first)
        #expect(run.state == .interrupted)
        #expect(run.counts == counts(running: 1, interrupted: 1))
    }

    @Test func stillReadsAsFailedWhenARunHasBothAFailureAndInterruptedWork() {
        let run = BoardRun.group([
            boardJob("job-01", run: "run-a", status: .interrupted),
            boardJob("job-02", run: "run-a", status: .failed),
        ]).first
        #expect(run?.state == .failed)
    }

    @Test func countsABlockedWorkerInItsOwnLane() throws {
        let run = try #require(BoardRun.group([
            boardJob("job-01", run: "run-a", status: .blocked),
            boardJob("job-02", run: "run-a", status: .done),
        ]).first)
        #expect(run.state == .blocked)
        #expect(run.counts == counts(blocked: 1, finished: 1))
    }

    @Test func ranksBlockedAboveEveryOtherLane() {
        for status: JobStatus in [.failed, .interrupted, .running, .queued, .done] {
            let run = BoardRun.group([
                boardJob("job-01", run: "run-a", status: status),
                boardJob("job-02", run: "run-a", status: .blocked),
            ]).first
            #expect(run?.state == .blocked)
        }
    }

    @Test func leadsTheLaneOrderWithBlocked() {
        #expect(RunLane.allCases.first == .blocked)
        #expect(RunLane.allCases.map(\.rawValue).sorted()
            == ["blocked", "failed", "finished", "interrupted", "queued", "running"])
    }

    @Test func hasNoStateToReportForAnEmptyRun() {
        #expect(BoardRun.group([]) == [])
    }
}

@Suite struct AttentionTests {
    @Test func reportsNothingWhenNoWorkIsWaitingOnTheUser() {
        #expect(RunCounts(jobs: [boardJob("a", run: "r", status: .running)]).attention == nil)
        #expect(RunCounts().attention == nil)
    }

    @Test func putsBlockedWorkAheadOfFailuresAndInterruptions() {
        let counts = RunCounts(jobs: [
            boardJob("a", run: "r", status: .failed),
            boardJob("b", run: "r", status: .interrupted),
            boardJob("c", run: "r", status: .blocked),
            boardJob("d", run: "r", status: .blocked),
        ])
        #expect(counts.attention == RunAttention(lane: .blocked, count: 2))
    }

    @Test func fallsBackToFailuresThenToInterruptions() {
        #expect(RunCounts(jobs: [
            boardJob("a", run: "r", status: .failed),
            boardJob("b", run: "r", status: .interrupted),
        ]).attention == RunAttention(lane: .failed, count: 1))
        #expect(RunCounts(jobs: [boardJob("a", run: "r", status: .interrupted)]).attention
            == RunAttention(lane: .interrupted, count: 1))
    }
}

private func planner(_ id: String, _ label: String, agent: String = "claude") -> Planner {
    Planner(id: id, label: label, agent: agent)
}

@Suite struct GroupPlannersTests {
    @Test func makesOneGroupPerDeclaredPlannerOrderedByLabel() {
        let groups = PlannerGroup.group(
            jobs: [boardJob("job-01", run: "run-a", planner: "pty-2")],
            planners: [planner("pty-2", "refactor pty"), planner("pty-1", "migrate CI")]
        )
        #expect(groups.map(\.id) == ["pty-1", "pty-2"])
        #expect(groups.map(\.label) == ["migrate CI", "refactor pty"])
        #expect(groups.map(\.agent) == ["claude", "claude"])
    }

    @Test func keepsADeclaredPlannerThatHasDelegatedNothing() throws {
        let group = try #require(PlannerGroup.group(jobs: [], planners: [planner("pty-1", "migrate CI")]).first)
        #expect(group.id == "pty-1")
        #expect(group.label == "migrate CI")
        #expect(group.state == .finished)
        #expect(group.runs == [])
        #expect(group.jobs == [])
        #expect(group.counts == RunCounts())
    }

    @Test func groupsEveryRunOfAPlannerUnderItsOwnTab() throws {
        let group = try #require(PlannerGroup.group(
            jobs: [
                boardJob("job-01", run: "run-a", planner: "pty-1"),
                boardJob("job-02", run: "run-b", planner: "pty-1"),
                boardJob("job-03", run: "run-a", planner: "pty-1"),
            ],
            planners: [planner("pty-1", "refactor pty")]
        ).first)
        #expect(group.runs.map(\.id) == ["run-a", "run-b"])
        #expect(group.runs[0].jobs.map(\.id) == ["job-01", "job-03"])
        #expect(group.jobs.count == 3)
    }

    @Test func putsTheJobsWithNoPlannerInALastUnlabelledGroup() {
        let groups = PlannerGroup.group(
            jobs: [
                boardJob("job-01", run: "run-a", planner: nil),
                boardJob("job-02", run: "run-b", planner: "pty-1"),
            ],
            planners: [planner("pty-1", "refactor pty")]
        )
        #expect(groups.map(\.id) == ["pty-1", nil])
        #expect(groups[1].label == nil)
        #expect(groups[1].agent == nil)
        #expect(groups[1].jobs.map(\.id) == ["job-01"])
    }

    @Test func neverDropsJobsWhosePlannerIsNoLongerDeclared() {
        let groups = PlannerGroup.group(
            jobs: [
                boardJob("job-01", run: "run-a", planner: "pty-gone"),
                boardJob("job-02", run: "run-b", planner: nil),
            ],
            planners: []
        )
        #expect(groups.map(\.id) == ["pty-gone", nil])
        #expect(groups[0].label == "pty-gone")
        #expect(groups[0].agent == nil)
    }

    @Test func reportsTheWorstStateAcrossEveryRunOfThePlanner() throws {
        let group = try #require(PlannerGroup.group(
            jobs: [
                boardJob("job-01", run: "run-a", planner: "pty-1", status: .done),
                boardJob("job-02", run: "run-b", planner: "pty-1", status: .failed),
            ],
            planners: [planner("pty-1", "refactor pty")]
        ).first)
        #expect(group.state == .failed)
        #expect(group.counts == counts(failed: 1, finished: 1))
    }

    @Test func readsAsBlockedWhenAnyOfItsRunsIsWaitingOnTheUser() throws {
        let group = try #require(PlannerGroup.group(
            jobs: [
                boardJob("job-01", run: "run-a", planner: "pty-1", status: .failed),
                boardJob("job-02", run: "run-b", planner: "pty-1", status: .blocked),
            ],
            planners: [planner("pty-1", "refactor pty")]
        ).first)
        #expect(group.state == .blocked)
        #expect(group.runs.map(\.state) == [.failed, .blocked])
        #expect(group.counts.attention == RunAttention(lane: .blocked, count: 1))
    }

    @Test func fallsBackToThePlannerIDWhenTheTerminalHasNoUsableName() throws {
        let group = try #require(PlannerGroup.group(jobs: [], planners: [planner("pty-1", "   ", agent: "  ")]).first)
        #expect(group.label == "pty-1")
        #expect(group.agent == nil)
    }

    @Test func hasNothingToShowWithoutPlannersOrJobs() {
        #expect(PlannerGroup.group(jobs: [], planners: []) == [])
    }
}
