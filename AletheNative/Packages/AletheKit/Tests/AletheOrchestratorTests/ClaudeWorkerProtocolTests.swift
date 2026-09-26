import Foundation
import Testing
import AletheGit
import AletheIntegrations
@testable import AletheOrchestrator

private func transcript(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/claude"))
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
}

private func claudeJob(cwd: String = "/tmp/claude-worker") -> Job {
    Job(id: "job-01", plannerID: nil, agent: WorkerAgent.claude, runID: "run-01", runLabel: nil, spec: "do something", cwd: cwd)
}

/// Plays the core's part around the protocol (the P6-6 core replaces it): spawning writes the first
/// turn, a turn's end computes the diff then finishes it like upstream `finish_turn` (not terminal:
/// the process stays parked), and every line written to the worker is recorded.
private struct ClaudeReplay {
    var job: Job
    var written: [OrderedJSON] = []
    var announced: [ClaudeTurnEnd] = []
    var computesDiff = false

    init(job: Job, computesDiff: Bool = false) {
        self.job = job
        self.computesDiff = computesDiff
        self.job.status = .running
        written.append(ClaudeWorkerProtocol.firstTurn(&self.job))
    }

    mutating func feed(_ lines: [String]) async {
        for line in lines {
            guard let message = ClaudeWorkerProtocol.parse(line: line) else { continue }
            guard case .turnEnded(let end) = ClaudeWorkerProtocol.handle(message, job: &job) else { continue }
            if computesDiff, let diff = await ClaudeWorkerProtocol.uncommittedDiff(in: job.cwd) {
                job.diff = diff
            }
            finish(end)
        }
    }

    mutating func finish(_ end: ClaudeTurnEnd) {
        guard !job.settled else { return }
        job.status = end.status
        job.pending = nil
        let text = end.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { job.report = text }
        job.outcome = end.outcome
        job.endedAt = 1
        job.activeTurnID = nil
        if end.announce { announced.append(end) }
        if let next = ClaudeWorkerProtocol.nextTurn(&job) {
            job.status = .running
            job.outcome = nil
            job.endedAt = nil
            job.reply = ""
            job.report = ""
            written.append(next)
        }
    }
}

private func userText(_ message: OrderedJSON) -> String? {
    message.objectValue?["message"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
}

private func tokens(_ job: Job, _ side: String, _ key: String) -> UInt64? {
    job.tokens?.objectValue?[side]?.objectValue?[key]?.uint64Value
}

@Suite(.timeLimit(.minutes(1))) struct ClaudeWorkerGoldenTests {
    // Upstream `a_claude_worker_reports_its_result_and_tokens`.
    @Test func aClaudeWorkerReportsItsResultAndTokens() async throws {
        var replay = ClaudeReplay(job: claudeJob())
        await replay.feed(try transcript("result-and-tokens"))

        let snapshot = replay.job.snapshot(nowMs: 2).json.objectValue
        #expect(snapshot?["agent"] == "claude")
        #expect(snapshot?["status"] == "done")
        #expect(snapshot?["outcome"] == "succeeded")
        #expect(snapshot?["threadId"] == "fake-session-1")
        #expect(snapshot?["summary"] == "CLAUDE_DONE_OK")
        #expect(tokens(replay.job, "total", "totalTokens") == 15)
        #expect(tokens(replay.job, "total", "inputTokens") == 3)
        #expect(tokens(replay.job, "last", "outputTokens") == 5)
        #expect(replay.job.costUSD == 0.0123)
        #expect(replay.announced.count == 1)

        // What outlives the process keeps the tokens and the cost.
        let restored = try #require(Job(record: replay.job.record))
        #expect(tokens(restored, "total", "totalTokens") == 15)
        #expect(restored.costUSD == 0.0123)
    }

    // Upstream `a_claude_worker_picks_up_its_own_uncommitted_changes_as_a_diff`.
    @Test func aClaudeWorkerPicksUpItsOwnUncommittedChangesAsADiff() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-orch-claude-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = GitRunner()
        for args in [["init", "-q"], ["config", "user.email", "lab@example.com"], ["config", "user.name", "lab"]] {
            _ = try await git.run(args, in: dir)
        }
        let file = dir.appendingPathComponent("file.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        for args in [["add", "-A"], ["commit", "-qm", "seed"]] {
            _ = try await git.run(args, in: dir)
        }
        try "after\n".write(to: file, atomically: true, encoding: .utf8)

        var replay = ClaudeReplay(job: claudeJob(cwd: dir.path), computesDiff: true)
        await replay.feed(try transcript("uncommitted-diff"))

        let snapshot = replay.job.snapshot(nowMs: 2)
        #expect(snapshot.status == .done)
        #expect(snapshot.hasDiff)
        #expect(replay.job.diff?.contains("+after") == true)
    }

    // Upstream `steering_a_running_claude_worker_interrupts_instead_of_waiting_out_the_turn`, carried
    // on through the aborted turn: it is not announced and the correction starts at once.
    @Test func steeringARunningClaudeWorkerInterruptsInsteadOfWaitingOutTheTurn() async throws {
        var replay = ClaudeReplay(job: claudeJob())
        await replay.feed(try transcript("steer-live-turn"))
        #expect(replay.job.status == .running)

        let steer = ClaudeWorkerProtocol.steer(&replay.job, message: "turn around", workerIsLive: true)
        #expect(steer.result.objectValue?["steered"] == "job-01")
        #expect(steer.result.objectValue?["queued"] == nil)
        guard case .interrupt(_, let request) = steer else {
            Issue.record("the steer only queued: \(steer)")
            return
        }
        replay.written.append(request)
        #expect(request.compactRendered()
            == #"{"type":"control_request","request_id":"job-01-interrupt-11","request":{"subtype":"interrupt"}}"#)
        #expect(replay.job.status == .running, "the interrupt settled the job instead of restarting it")

        await replay.feed(try transcript("steer-live-after-interrupt"))
        #expect(replay.written.count == 3)
        #expect(userText(replay.written[2]) == "turn around")
        #expect(replay.announced.map(\.text) == ["TURNED_AROUND"], "the aborted turn was announced")
        #expect(replay.job.status == .done)
        #expect(replay.job.report == "TURNED_AROUND")
        #expect(replay.job.awaitingSteer == false)
        // The aborted turn still counts.
        #expect(tokens(replay.job, "total", "totalTokens") == 10)
        #expect(abs((replay.job.costUSD ?? 0) - 0.003) < 1e-12)
    }

    // Upstream `steering_a_settled_claude_worker_queues_the_next_turn`.
    @Test func steeringASettledClaudeWorkerQueuesTheNextTurn() async throws {
        var replay = ClaudeReplay(job: claudeJob())
        await replay.feed(try transcript("steer-idle"))
        #expect(replay.job.status == .done)

        let steer = ClaudeWorkerProtocol.steer(&replay.job, message: "one more thing", workerIsLive: true)
        #expect(steer.result.objectValue?["queued"] == "job-01")
        #expect(steer.result.objectValue?["waiting"] == 1)
        #expect(replay.job.inbox == ["one more thing"])
        #expect(replay.job.awaitingSteer == false)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ClaudeWorkerProtocolTests {
    @Test func theFirstTurnIsTheTaskUnlessWorkWaited() {
        var job = claudeJob()
        #expect(ClaudeWorkerProtocol.firstTurn(&job).compactRendered()
            == #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do something"}]}}"#)
        job.inbox = ["waiting first", "then this"]
        #expect(userText(ClaudeWorkerProtocol.firstTurn(&job)) == "waiting first")
        #expect(job.inbox == ["then this"])
    }

    @Test func anInterruptedJobResumesItsSession() {
        let launcher = Launcher(kind: "claude", program: URL(fileURLWithPath: "/usr/local/bin/claude"), arguments: ["-p"])
        #expect(ClaudeWorkerProtocol.arguments(launcher, resuming: nil) == ["-p"])
        #expect(ClaudeWorkerProtocol.arguments(launcher, resuming: "abc") == ["-p", "--resume", "abc"])
    }

    @Test func theSessionIdIsKeptFromTheFirstInit() {
        var job = claudeJob()
        #expect(ClaudeWorkerProtocol.handle(["type": "system", "subtype": "init", "session_id": "one"], job: &job) == .updated)
        _ = ClaudeWorkerProtocol.handle(["type": "system", "subtype": "init", "session_id": "two"], job: &job)
        #expect(job.threadID == "one")
    }

    @Test func aDeniedToolCallIsReportedInTheReply() {
        var job = claudeJob()
        _ = ClaudeWorkerProtocol.handle(["type": "system", "subtype": "permission_denied", "message": "Bash denied"], job: &job)
        _ = ClaudeWorkerProtocol.handle(["type": "system", "subtype": "permission_denied"], job: &job)
        #expect(job.reply == "\n[blocked] Bash denied\n\n[blocked] a tool call was denied permission\n")
    }

    @Test func onlyTextBlocksReachTheReply() {
        var job = claudeJob()
        let message: OrderedJSON = ["type": "assistant", "message": ["content": [
            ["type": "text", "text": "a"],
            ["type": "tool_use", "name": "Bash"],
            ["type": "text", "text": "b"],
        ]]]
        #expect(ClaudeWorkerProtocol.handle(message, job: &job) == .updated)
        #expect(job.reply == "ab")
        let toolOnly: OrderedJSON = ["type": "assistant", "message": ["content": [["type": "tool_use"]]]]
        #expect(ClaudeWorkerProtocol.handle(toolOnly, job: &job) == .ignored)
    }

    @Test func theLiveReplyKeepsOnlyItsEnd() {
        var job = claudeJob()
        job.reply = String(repeating: "a", count: OrchestratorLimits.replyLimit)
        _ = ClaudeWorkerProtocol.handle(["type": "assistant", "message": ["content": [["type": "text", "text": "zz"]]]], job: &job)
        #expect(job.reply.count == OrchestratorLimits.replyLimit)
        #expect(job.reply.hasSuffix("zz"))
    }

    @Test func aRateLimitEventIsTheLiveQuota() {
        var job = claudeJob()
        let info: OrderedJSON = ["status": "allowed_warning", "resetsAt": 1_700_000_000]
        #expect(ClaudeWorkerProtocol.handle(["type": "rate_limit_event", "rate_limit_info": info], job: &job) == .updated)
        #expect(job.quota == info)
        #expect(ClaudeWorkerProtocol.handle(["type": "rate_limit_event"], job: &job) == .ignored)
    }

    @Test func anErrorResultFailsAndAnEmptyResultFallsBackToTheReply() {
        var job = claudeJob()
        job.reply = "  the reply's end  "
        let end = ClaudeWorkerProtocol.handle(["type": "result", "is_error": true, "result": "  "], job: &job)
        #expect(end == .turnEnded(ClaudeTurnEnd(status: .failed, outcome: "failed", text: "the reply's end", announce: true)))
    }

    @Test func tokensAndCostAddUpAcrossTurns() {
        var job = claudeJob()
        let turn: OrderedJSON = ["type": "result", "result": "ok", "total_cost_usd": .double(0.5),
                                 "usage": ["input_tokens": 1, "output_tokens": 2, "cache_creation_input_tokens": 3]]
        _ = ClaudeWorkerProtocol.handle(turn, job: &job)
        _ = ClaudeWorkerProtocol.handle(turn, job: &job)
        #expect(tokens(job, "total", "totalTokens") == 12)
        #expect(tokens(job, "total", "cacheCreationInputTokens") == 6)
        #expect(tokens(job, "last", "totalTokens") == 6)
        #expect(job.costUSD == 1.0)
        // A negative or missing cost is not counted.
        _ = ClaudeWorkerProtocol.handle(["type": "result", "result": "ok", "total_cost_usd": -1], job: &job)
        #expect(job.costUSD == 1.0)
    }

    @Test func steeringWithoutALiveWorkerQueues() {
        var job = claudeJob()
        job.status = .running
        let steer = ClaudeWorkerProtocol.steer(&job, message: "later", workerIsLive: false)
        #expect(steer == .queued(jobID: "job-01", waiting: 1))
        #expect(job.awaitingSteer == false)
    }

    @Test func cancellingClearsTheCLIQueueAndAnyPendingSteer() {
        var job = claudeJob()
        job.awaitingSteer = true
        let request = ClaudeWorkerProtocol.cancel(&job)
        #expect(request.compactRendered()
            == #"{"type":"control_request","request_id":"job-01-interrupt-11","request":{"subtype":"interrupt","cancel_queued":true}}"#)
        #expect(job.awaitingSteer == false)
        #expect(ClaudeWorkerProtocol.cancel(&job).objectValue?["request_id"] == "job-01-interrupt-12")
    }

    @Test func theNextTurnNeedsASessionAndAQueuedMessage() {
        var job = claudeJob()
        job.inbox = ["follow-up"]
        #expect(ClaudeWorkerProtocol.nextTurn(&job) == nil)
        job.threadID = "s"
        #expect(ClaudeWorkerProtocol.nextTurn(&job).flatMap(userText) == "follow-up")
        #expect(ClaudeWorkerProtocol.nextTurn(&job) == nil)
    }

    @Test func blankAndInvalidLinesAreSkippedAndLinesEndInANewline() {
        #expect(ClaudeWorkerProtocol.parse(line: "   ") == nil)
        #expect(ClaudeWorkerProtocol.parse(line: "not json") == nil)
        #expect(ClaudeWorkerProtocol.parse(line: #"{"type":"x"}"#) == ["type": "x"])
        #expect(ClaudeWorkerProtocol.line(["type": "x"]) == Data(#"{"type":"x"}"#.utf8 + [0x0A]))
        var job = claudeJob()
        #expect(ClaudeWorkerProtocol.handle(["type": "stream_event"], job: &job) == .ignored)
        #expect(ClaudeWorkerProtocol.handle("text", job: &job) == .ignored)
    }
}
