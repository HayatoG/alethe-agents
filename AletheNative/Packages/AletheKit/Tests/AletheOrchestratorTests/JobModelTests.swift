import Foundation
import Testing
import AletheIntegrations
@testable import AletheOrchestrator

private func job() -> Job {
    var job = Job(
        id: "job-03",
        plannerID: "tab-1",
        agent: "codex",
        runID: "run-02",
        runLabel: "a run",
        spec: "fix the parser",
        cwd: "/tmp/repo",
        status: .running,
        worktree: "/tmp/repo/.alethe/worktrees/job-03",
        approvalPolicy: #""never""#
    )
    job.threadID = "thread-9"
    job.reply = "narration then the end"
    job.report = "  the conclusion  "
    job.plan = ["read", "write"]
    job.diff = "diff --git a/x b/x"
    job.tokens = ["total": ["totalTokens": 12], "last": ["totalTokens": 5]]
    job.costUSD = 0.25
    job.startedAt = 1_000
    job.endedAt = 3_500
    job.outcome = "completed"
    return job
}

@Suite struct JobModelTests {
    @Test func statusesAndWhichAreSettled() {
        #expect(JobStatus.allCases.map(\.rawValue) == [
            "queued", "running", "blocked", "done", "failed", "cancelled", "released", "interrupted",
        ])
        #expect(JobStatus.allCases.filter(\.settled) == [.done, .failed, .cancelled, .released, .interrupted])
    }

    // The snapshot in upstream's `Job::snapshot` JSON, key for key and in order.
    @Test func theSnapshotMatchesUpstreamJSON() throws {
        let snapshot = job().snapshot(nowMs: 9_999)
        let expected = """
        {"id":"job-03","plannerId":"tab-1","agent":"codex","runId":"run-02","runLabel":"a run",\
        "spec":"fix the parser","cwd":"/tmp/repo","status":"running","threadId":"thread-9",\
        "outcome":"completed","seconds":2.5,"plan":["read","write"],\
        "tokens":{"total":{"totalTokens":12},"last":{"totalTokens":5}},"costUsd":0.25,"quota":null,\
        "routing":null,"worktree":"/tmp/repo/.alethe/worktrees/job-03","pendingApproval":null,\
        "hasDiff":true,"summary":"the conclusion"}
        """
        #expect(snapshot.json.compactRendered() == expected)
    }

    @Test func aFreshJobSnapshotsWithNullsAndTheLiveReply() {
        var fresh = Job(id: "job-01", plannerID: nil, agent: "claude", runID: "run-01", runLabel: nil, spec: "s", cwd: "/")
        fresh.reply = "still going"
        let snapshot = fresh.snapshot(nowMs: 0)
        #expect(snapshot.seconds == nil)
        #expect(snapshot.summary == "still going")
        #expect(snapshot.hasDiff == false)
        let object = snapshot.json.objectValue
        #expect(object?["plannerId"] == .null)
        #expect(object?["seconds"] == .null)
        #expect(object?["native"] == nil)
    }

    @Test func aRunningJobCountsItsSecondsUpToNow() {
        var running = job()
        running.endedAt = nil
        #expect(running.snapshot(nowMs: 4_000).seconds == 3.0)
        #expect(running.snapshot(nowMs: 4_000).json.objectValue?["seconds"]?.compactRendered() == "3.0")
    }

    @Test func theSummaryKeepsOnlyTheEndOfALongReport() {
        var long = job()
        long.report = String(repeating: "a", count: 2000) + String(repeating: "z", count: 1200)
        #expect(long.snapshot(nowMs: 0).summary == String(repeating: "z", count: 1200))
    }

    // The record in upstream's `Job::record` JSON.
    @Test func theRecordMatchesUpstreamJSON() {
        let expected = """
        {"id":"job-03","plannerId":"tab-1","agent":"codex","runId":"run-02","runLabel":"a run",\
        "spec":"fix the parser","cwd":"/tmp/repo","status":"running","threadId":"thread-9",\
        "outcome":"completed","plan":["read","write"],\
        "tokens":{"total":{"totalTokens":12},"last":{"totalTokens":5}},"costUsd":0.25,\
        "worktree":"/tmp/repo/.alethe/worktrees/job-03","approvalPolicy":"\\"never\\"",\
        "sandbox":"workspace-write","webSearch":false,"summary":"  the conclusion  ",\
        "startedAt":1000,"endedAt":3500}
        """
        #expect(job().record.compactRendered() == expected)
    }

    @Test func aRecordRoundTripsAndInFlightWorkComesBackInterrupted() throws {
        let restored = try #require(Job(record: job().record))
        #expect(restored.status == .interrupted)
        #expect(restored.report == "  the conclusion  ")
        #expect(restored.plan == ["read", "write"])
        #expect(restored.tokens == job().tokens)
        #expect(restored.costUSD == 0.25)
        #expect(restored.startedAt == 1_000 && restored.endedAt == 3_500)
        #expect(restored.approvalPolicyValue == "never")
        // Live-only state does not survive.
        #expect(restored.diff == nil && restored.pending == nil && restored.reply.isEmpty)

        var queued = job()
        queued.status = .queued
        #expect(Job(record: queued.record)?.status == .interrupted)
        var failed = job()
        failed.status = .failed
        #expect(Job(record: failed.record)?.status == .failed)
    }

    @Test func aSparseRecordTakesUpstreamDefaults() throws {
        let restored = try #require(Job(record: ["id": "job-12", "tokens": .null]))
        #expect(restored.status == .done)
        #expect(restored.agent == "codex")
        #expect(restored.runID == "run-00")
        #expect(restored.spec.isEmpty && restored.cwd.isEmpty)
        #expect(restored.approvalPolicy == "never")
        #expect(restored.sandbox == "workspace-write")
        #expect(restored.webSearch == false)
        #expect(restored.tokens == nil)
        #expect(restored.timeoutMs == 900_000)
        #expect(restored.nextRequestID == 10)
        #expect(Job(record: ["spec": "no id"]) == nil)
    }

    @Test func theGranularPolicyIsReadBackAsAnObject() {
        var asking = job()
        asking.approvalPolicy = #"{"granular":{"sandbox_approval":true}}"#
        #expect(asking.approvalPolicyValue == ["granular": ["sandbox_approval": true]])
        asking.approvalPolicy = "not json"
        #expect(asking.approvalPolicyValue == "never")
    }

    @Test func theCoreSnapshotAndItsParts() {
        let snapshot = OrchestratorSnapshot(
            jobs: [],
            planners: [Planner(id: "tab-1", label: "Claude", agent: "claude")],
            running: 1,
            queued: 2
        )
        #expect(snapshot.json.compactRendered()
            == #"{"jobs":[],"planners":[{"id":"tab-1","label":"Claude","agent":"claude"}],"running":1,"queued":2,"concurrencyLimit":4}"#)
        #expect(Planner(json: ["id": "tab-2"]) == Planner(id: "tab-2", label: "tab-2", agent: ""))
        #expect(Planner(json: ["label": "x"]) == nil)

        let delivery = Delivery(sequence: 3, kind: "result", jobID: "job-01", outcome: nil, text: "done")
        #expect(delivery.json.compactRendered() == #"{"seq":3,"type":"result","jobId":"job-01","outcome":null,"text":"done"}"#)
    }

    @Test func idsAndTheirTrailingNumbers() {
        #expect(OrchestratorID.job(7) == "job-07")
        #expect(OrchestratorID.run(12) == "run-12")
        #expect(OrchestratorID.job(123) == "job-123")
        #expect(OrchestratorID.trailingNumber("job-07") == 7)
        #expect(OrchestratorID.trailingNumber("run-120") == 120)
        #expect(OrchestratorID.trailingNumber("job-x") == 0)
        #expect(OrchestratorID.trailingNumber("plain") == 0)
        #expect(OrchestratorID.trailingNumber("") == 0)
    }

    @Test func tailKeepsTheEndTrimmed() {
        #expect(orchestratorTail("  short  ", limit: 10) == "short")
        #expect(orchestratorTail("abcdef", limit: 3) == "def")
        #expect(orchestratorTail("héllo wörld", limit: 5) == "wörld")
    }

    @Test func claudeUsageBecomesATokenCount() {
        let usage: OrderedJSON = [
            "input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 300,
            "cache_creation_input_tokens": 4, "service_tier": "standard",
        ]
        #expect(TokenCounts.claude(usage: usage).compactRendered()
            == #"{"totalTokens":334,"inputTokens":10,"outputTokens":20,"cachedInputTokens":300,"cacheCreationInputTokens":4}"#)
        #expect(TokenCounts.claude(usage: .null).objectValue?["totalTokens"] == 0)
    }

    @Test func tokenCountsAddKeyByKey() {
        let total: OrderedJSON = ["totalTokens": 100, "inputTokens": 60, "outputTokens": 40]
        let turn: OrderedJSON = ["totalTokens": 7, "cachedInputTokens": 3, "cacheCreationInputTokens": 1]
        #expect(TokenCounts.adding(total, turn).compactRendered()
            == #"{"totalTokens":107,"inputTokens":60,"outputTokens":40,"cachedInputTokens":3,"cacheCreationInputTokens":1}"#)
        let huge: OrderedJSON = ["totalTokens": .unsigned(.max)]
        #expect(TokenCounts.adding(huge, huge).objectValue?["totalTokens"]?.uint64Value == .max)
    }

    @Test func aLauncherCarriesKindProgramArgumentsAndEnvironment() {
        let launcher = Launcher(kind: "codex", program: URL(filePath: "/usr/local/bin/codex"), arguments: ["app-server"])
        #expect(launcher.environment.isEmpty)
        #expect(launcher.kind == WorkerAgent.codex)
    }
}
