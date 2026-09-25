import Foundation
import Testing
import AletheIntegrations
@testable import AletheOrchestrator

/// Recorded Codex `app-server` transcripts. Upstream's Codex cases (`two_workers_overlap_…`,
/// `the_queue_never_breaches_…`, `a_worker_that_never_finishes_…`) drive real or silent processes;
/// these are the worker's stdout for those runs, one JSON message per line, replayed without a process.
private enum Transcript {
    /// A worker asked to create ALPHA.txt (upstream `two_workers_overlap_and_check_waits_for_both`).
    static let alpha = """
    {"id":1,"result":{"userAgent":"codex_app_server/0.46.0","platformFamily":"unix","platformOs":"macos"}}
    {"id":2,"result":{"thread":{"id":"thr_alpha","preview":"","modelProvider":"openai","createdAt":1758800000},"model":"gpt-5-codex","cwd":"/tmp/alethe-orch-parallel","approvalPolicy":"never","sandbox":{"type":"workspaceWrite"}}}
    {"method":"thread/started","params":{"thread":{"id":"thr_alpha"}}}
    {"id":3,"result":{"turn":{"id":"turn_1","items":[],"status":"inProgress"}}}
    {"method":"turn/started","params":{"threadId":"thr_alpha","turn":{"id":"turn_1","items":[],"status":"inProgress"}}}
    {"method":"turn/plan/updated","params":{"threadId":"thr_alpha","turnId":"turn_1","explanation":null,"plan":[{"step":"Create ALPHA.txt","status":"inProgress"},{"step":"Confirm its content","status":"pending"}]}}
    {"method":"item/started","params":{"threadId":"thr_alpha","turnId":"turn_1","item":{"type":"agentMessage","id":"msg_1","text":""}}}
    {"method":"item/agentMessage/delta","params":{"threadId":"thr_alpha","turnId":"turn_1","itemId":"msg_1","delta":"Creating ALPHA.txt "}}
    {"method":"item/agentMessage/delta","params":{"threadId":"thr_alpha","turnId":"turn_1","itemId":"msg_1","delta":"now."}}
    {"method":"item/completed","params":{"threadId":"thr_alpha","turnId":"turn_1","item":{"type":"agentMessage","id":"msg_1","text":"Creating ALPHA.txt now."}}}
    {"method":"item/completed","params":{"threadId":"thr_alpha","turnId":"turn_1","item":{"type":"fileChange","id":"fc_1","changes":[{"path":"ALPHA.txt","kind":"add"}],"status":"completed"}}}
    {"method":"turn/diff/updated","params":{"threadId":"thr_alpha","turnId":"turn_1","diff":"diff --git a/ALPHA.txt b/ALPHA.txt\\nnew file mode 100644\\n--- /dev/null\\n+++ b/ALPHA.txt\\n@@ -0,0 +1 @@\\n+ALPHA\\n"}}
    {"method":"thread/tokenUsage/updated","params":{"threadId":"thr_alpha","turnId":"turn_1","tokenUsage":{"total":{"totalTokens":5120,"inputTokens":4800,"cachedInputTokens":3072,"outputTokens":320,"reasoningOutputTokens":64},"last":{"totalTokens":5120,"inputTokens":4800,"cachedInputTokens":3072,"outputTokens":320,"reasoningOutputTokens":64},"modelContextWindow":272000}}}
    {"method":"item/completed","params":{"threadId":"thr_alpha","turnId":"turn_1","item":{"type":"agentMessage","id":"msg_2","text":"  Created ALPHA.txt containing ALPHA.  "}}}
    {"method":"turn/completed","params":{"threadId":"thr_alpha","turn":{"id":"turn_1","items":[],"status":"completed"}}}
    """

    /// What Alethe wrote to that worker, in order.
    static let alphaWritten = """
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"alethe-orchestrator","title":"Alethe","version":"1"},"capabilities":{"experimentalApi":true}}}
    {"method":"initialized"}
    {"id":2,"method":"thread/start","params":{"cwd":"/tmp/alethe-orch-parallel","approvalPolicy":"never","approvalsReviewer":"user","sandbox":"workspace-write","config":{"tools":{"web_search":{"mode":"disabled"}}}}}
    {"id":3,"method":"turn/start","params":{"threadId":"thr_alpha","input":[{"type":"text","text":"Create a file ALPHA.txt whose entire content is the word ALPHA."}],"approvalPolicy":"never"}}
    """

    /// A worker delegated with `askForApproval` that wants the network (upstream
    /// `the_handshake_offers_a_way_to_answer_a_blocked_worker`, carried through to the answer).
    static let blocked = """
    {"id":1,"result":{"userAgent":"codex_app_server/0.46.0"}}
    {"id":2,"result":{"thread":{"id":"thr_ask"}}}
    {"method":"turn/started","params":{"threadId":"thr_ask","turn":{"id":"turn_7","items":[],"status":"inProgress"}}}
    {"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_ask","turnId":"turn_7","itemId":"cmd_1","command":"curl -sSf https://example.com","cwd":"/tmp/repo","reason":"needs network access"}}
    """

    static let blockedAfterAnswer = """
    {"method":"item/completed","params":{"threadId":"thr_ask","turnId":"turn_7","item":{"type":"agentMessage","id":"msg_1","text":"Fetched the page."}}}
    {"method":"turn/completed","params":{"threadId":"thr_ask","turn":{"id":"turn_7","items":[],"status":"completed"}}}
    """

    /// A worker that starts a turn and then never finishes it (upstream
    /// `a_worker_that_never_finishes_is_stopped_by_its_budget`, with a turn in flight).
    static let hanging = """
    {"id":1,"result":{}}
    {"id":2,"result":{"thread":{"id":"thr_hang"}}}
    {"method":"turn/started","params":{"threadId":"thr_hang","turn":{"id":"turn_1","items":[],"status":"inProgress"}}}
    """

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }
}

/// Replays a transcript and returns everything written back plus the events, in order.
private func replay(_ session: inout CodexWorkerSession, _ transcript: String, nowMs: UInt64 = 42) -> CodexWorkerStep {
    var total = CodexWorkerStep()
    for line in Transcript.lines(transcript) {
        let step = session.receive(line: line, nowMs: nowMs)
        total.outgoing += step.outgoing
        total.events += step.events
    }
    return total
}

private func rendered(_ messages: [OrderedJSON]) -> [String] {
    messages.map { $0.compactRendered() }
}

private func alphaSession() -> CodexWorkerSession {
    CodexWorkerSession(
        jobID: "job-01",
        cwd: "/tmp/alethe-orch-parallel",
        firstTurn: "Create a file ALPHA.txt whose entire content is the word ALPHA."
    )
}

@Suite struct CodexWorkerProtocolGoldenTests {
    // Upstream `the_handshake_offers_a_way_to_answer_a_blocked_worker`.
    @Test func theHandshakeOffersAWayToAnswerABlockedWorker() throws {
        let tools = try #require(OrchestratorMCP.tools.arrayValue)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("alethe_answer"))
        let delegate = try #require(tools.first { $0.objectValue?["name"] == "alethe_delegate" })
        let ask = delegate.objectValue?["inputSchema"]?.objectValue?["properties"]?.objectValue?["askForApproval"]
        #expect(ask?.objectValue != nil, "delegation has to be able to ask for approval")
    }

    // Upstream `two_workers_overlap_and_check_waits_for_both`, one worker's side of the wire.
    @Test func aCodexWorkerCreatesItsFileAndReportsItsOwnConclusion() {
        var session = alphaSession()
        var written = session.handshake()
        let step = replay(&session, Transcript.alpha)
        written += step.outgoing
        #expect(rendered(written) == Transcript.lines(Transcript.alphaWritten))

        var job = Job(id: "job-01", plannerID: nil, agent: "codex", runID: "run-01", runLabel: nil,
                      spec: session.firstTurn, cwd: session.cwd, status: .running)
        for event in step.events { job.apply(event) }
        #expect(job.threadID == "thr_alpha")
        #expect(job.plan == ["Create ALPHA.txt", "Confirm its content"])
        #expect(job.reply == "Creating ALPHA.txt now.")
        #expect(job.report == "Created ALPHA.txt containing ALPHA.")
        #expect(job.diff?.contains("+ALPHA") == true)
        #expect(job.tokens?.objectValue?["total"]?.objectValue?["totalTokens"] == 5120)
        #expect(job.activeTurnID == nil)
        #expect(step.events.last == .turnEnded(succeeded: true, summary: "Created ALPHA.txt containing ALPHA."))
    }

    // Upstream `a_worker_that_never_finishes_is_stopped_by_its_budget`: the watchdog interrupts the
    // turn in flight on the job's own request ids, and a worker that never spoke gets no interrupt.
    @Test func aWorkerThatNeverFinishesIsInterruptedOnItsOwnTurn() {
        var silent = CodexWorkerSession(jobID: "job-01", cwd: "/tmp/w", firstTurn: "hang forever")
        #expect(silent.interrupt() == nil)
        #expect(silent.nextRequestID == 10)

        var session = CodexWorkerSession(jobID: "job-02", cwd: "/tmp/w", firstTurn: "hang forever")
        _ = replay(&session, Transcript.hanging)
        let interrupt = session.interrupt()
        #expect(interrupt?.compactRendered()
            == #"{"id":11,"method":"turn/interrupt","params":{"threadId":"thr_hang","turnId":"turn_1"}}"#)
    }

    // A blocked worker waits on its question, and the planner's answer goes back on the worker's id.
    @Test func aBlockedWorkerIsAnsweredOnTheIdItAskedWith() throws {
        let policy = CodexApprovalPolicy.policy(askForApproval: true)
        var job = Job(id: "job-04", plannerID: "tab-1", agent: "codex", runID: "run-02", runLabel: nil,
                      spec: "fetch the page", cwd: "/tmp/repo", status: .running,
                      approvalPolicy: policy.approvalPolicy, sandbox: policy.sandbox)
        var session = CodexWorkerSession(job: job, firstTurn: job.spec)
        let opening = try #require(session.handshake().last)
        #expect(opening.compactRendered() == #"{"id":2,"method":"thread/start","params":{"cwd":"/tmp/repo","approvalPolicy":{"granular":{"sandbox_approval":true,"request_permissions":true,"rules":true,"skill_approval":true,"mcp_elicitations":true}},"approvalsReviewer":"user","sandbox":"workspace-write","config":{"tools":{"web_search":{"mode":"disabled"}}}}}"#)

        let asked = replay(&session, Transcript.blocked, nowMs: 1_700)
        for event in asked.events { job.apply(event) }
        #expect(job.status == .blocked)
        #expect(job.pending?.compactRendered() == #"{"rpcId":0,"kind":"command","command":"curl -sSf https://example.com","cwd":"/tmp/repo","reason":"needs network access","askedAtMs":1700}"#)
        // Nothing is answered on its own: the only write after the thread is the first turn.
        #expect(asked.outgoing.count == 1)

        let answer = try session.answer("accept")
        #expect(answer.compactRendered() == #"{"id":0,"result":{"decision":"accept"}}"#)
        #expect(session.pending == nil)

        let finished = replay(&session, Transcript.blockedAfterAnswer)
        #expect(finished.events.last == .turnEnded(succeeded: true, summary: "Fetched the page."))
    }
}

@Suite struct CodexWorkerProtocolTests {
    @Test func startingANewJobOpensAThreadWithItsSettings() {
        var session = CodexWorkerSession(jobID: "job-01", cwd: "/tmp/w", firstTurn: "x", webSearch: true)
        let handshake = rendered(session.handshake())
        #expect(handshake.count == 3)
        #expect(handshake[1] == #"{"method":"initialized"}"#)
        #expect(handshake[2].contains(#""method":"thread/start""#))
        #expect(handshake[2].contains(#""web_search":{"mode":"live"}"#))
        #expect(session.receive(line: #"{"id":1,"result":{}}"#).outgoing.isEmpty)
    }

    @Test func anInterruptedJobResumesItsThreadAndStartsTheQueuedTurnOnIt() throws {
        var job = Job(id: "job-05", plannerID: nil, agent: "codex", runID: "run-01", runLabel: nil,
                      spec: "the task", cwd: "/tmp/w", status: .interrupted)
        job.threadID = "thr_old"
        var session = CodexWorkerSession(job: job, firstTurn: "the follow-up")
        let opening = try #require(session.handshake().last)
        #expect(opening.compactRendered() == #"{"id":2,"method":"thread/resume","params":{"threadId":"thr_old","cwd":"/tmp/w"}}"#)

        let step = session.receive(line: #"{"id":2,"result":{"thread":{"id":"thr_old"}}}"#)
        #expect(step.events == [.threadReady(threadID: "thr_old")])
        #expect(rendered(step.outgoing) == [
            #"{"id":3,"method":"turn/start","params":{"threadId":"thr_old","input":[{"type":"text","text":"the follow-up"}],"approvalPolicy":"never"}}"#,
        ])
    }

    @Test func unknownRequestsAreRefusedSoTheWorkerNeverHangs() {
        var session = alphaSession()
        let step = session.receive(line: #"{"id":"r-9","method":"item/tool/requestUserInput","params":{}}"#)
        #expect(step.events.isEmpty)
        #expect(rendered(step.outgoing) == [
            #"{"id":"r-9","error":{"code":-32601,"message":"unsupported request item/tool/requestUserInput"}}"#,
        ])
        #expect(session.pending == nil)
    }

    @Test func aFileChangeApprovalIsItsOwnKind() {
        var session = alphaSession()
        let step = session.receive(line: #"{"id":5,"method":"item/fileChange/requestApproval","params":{"reason":"outside the workspace"}}"#, nowMs: 9)
        #expect(step.events == [.approvalRequested(CodexApprovalRequest(
            rpcID: 5, kind: .fileChange, command: nil, cwd: nil, reason: "outside the workspace", askedAtMs: 9
        ))])
        #expect(step.outgoing.isEmpty)
    }

    @Test func everyNotificationBecomesItsEvent() {
        var session = alphaSession()
        let lines = [
            #"{"method":"turn/started","params":{"turn":{"id":"t1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"hi"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","text":" done "}}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"   "}}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution"}}}"#,
            #"{"method":"turn/plan/updated","params":{"plan":[{"step":"a"},{"status":"pending"},{"step":"b"}]}}"#,
            #"{"method":"turn/diff/updated","params":{"diff":"d"}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":3}}}}"#,
            #"{"method":"something/else","params":{}}"#,
            #"{"method":"turn/failed","params":{}}"#,
        ]
        let events = lines.flatMap { session.receive(line: $0).events }
        #expect(events == [
            .turnStarted(turnID: "t1"),
            .replyDelta("hi"),
            .report("done"),
            .planUpdated(["a", "b"]),
            .diffUpdated("d"),
            .tokensUpdated(["total": ["totalTokens": 3]]),
            .turnEnded(succeeded: false, summary: "done"),
        ])
        #expect(session.activeTurnID == nil)
    }

    @Test func withoutAReportTheSummaryIsTheReplysEnd() {
        var session = alphaSession()
        _ = session.receive(line: #"{"method":"item/agentMessage/delta","params":{"delta":"  partial answer  "}}"#)
        let step = session.receive(line: #"{"method":"turn/completed","params":{}}"#)
        #expect(step.events == [.turnEnded(succeeded: true, summary: "partial answer")])
    }

    @Test func theLiveReplyKeepsOnlyItsEnd() {
        var job = Job(id: "job-01", plannerID: nil, agent: "codex", runID: "run-01", runLabel: nil, spec: "", cwd: "")
        job.apply(.replyDelta(String(repeating: "a", count: OrchestratorLimits.replyLimit)))
        job.apply(.replyDelta("END"))
        #expect(job.reply.count == OrchestratorLimits.replyLimit)
        #expect(job.reply.hasSuffix("aEND"))
    }

    @Test func blankAndInvalidLinesAreSkipped() {
        var session = alphaSession()
        for line in ["", "   ", "not json", "[1,2]", #"{"id":2,"result":{}}"#] {
            let step = session.receive(line: line)
            #expect(step.outgoing.isEmpty && step.events.isEmpty, "\(line)")
        }
        #expect(session.threadID == nil)
    }

    @Test func aFailedRequestIsReported() {
        var session = alphaSession()
        let step = session.receive(line: #"{"id":2,"error":{"code":-32600,"message":"no such thread"}}"#)
        #expect(step.events == [.requestFailed(id: 2, message: "no such thread")])
        #expect(step.outgoing.isEmpty)
    }

    @Test func laterRequestsCountUpPerJob() throws {
        var session = alphaSession()
        #expect(throws: OrchestratorToolError("job job-01 has no thread")) { try session.startTurn("x") }
        _ = session.receive(line: #"{"id":2,"result":{"thread":{"id":"thr"}}}"#)
        _ = session.receive(line: #"{"method":"turn/started","params":{"turn":{"id":"t1"}}}"#)
        let steer = try session.steer("focus on tests")
        #expect(steer.compactRendered() == #"{"id":11,"method":"turn/steer","params":{"threadId":"thr","input":[{"type":"text","text":"focus on tests"}],"expectedTurnId":"t1"}}"#)
        _ = session.receive(line: #"{"method":"turn/completed","params":{}}"#)
        #expect(throws: OrchestratorToolError("job job-01 has no running turn to steer")) { try session.steer("late") }
        let next = try session.startTurn("and now the docs")
        #expect(next.compactRendered() == #"{"id":12,"method":"turn/start","params":{"threadId":"thr","input":[{"type":"text","text":"and now the docs"}],"approvalPolicy":"never"}}"#)
        #expect(session.reply.isEmpty && session.report.isEmpty)
    }

    @Test func answersAreValidatedAndOnlyGoOutWhenSomethingWaits() throws {
        var session = alphaSession()
        #expect(throws: OrchestratorToolError("decision must be one of accept, acceptForSession, decline, abort")) {
            try session.answer("yes")
        }
        #expect(throws: OrchestratorToolError("job job-01 is not waiting on anything")) { try session.answer("accept") }
        for decision in CodexApprovalDecision.allCases {
            _ = session.receive(line: #"{"id":"q","method":"item/commandExecution/requestApproval","params":{}}"#)
            let answer = try session.answer(decision)
            #expect(answer == ["id": "q", "result": ["decision": .string(decision.rawValue)]])
        }
    }

    @Test func theEndOfATurnDropsAnUnansweredQuestion() {
        var session = alphaSession()
        _ = session.receive(line: #"{"id":4,"method":"item/fileChange/requestApproval","params":{}}"#)
        #expect(session.pending != nil)
        _ = session.receive(line: #"{"method":"turn/failed","params":{}}"#)
        #expect(session.pending == nil)
    }

    @Test func theApprovalPolicyWithoutAskingIsNever() {
        let policy = CodexApprovalPolicy.policy(askForApproval: false)
        #expect(policy.approvalPolicy == #""never""#)
        #expect(policy.sandbox == "workspace-write")
        let job = Job(id: "j", plannerID: nil, agent: "codex", runID: "r", runLabel: nil, spec: "", cwd: "",
                      approvalPolicy: policy.approvalPolicy)
        #expect(job.approvalPolicyValue == "never")
    }

    @Test func thePumpWritesWhatEachLineProducesInOrder() async throws {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        for line in Transcript.lines(Transcript.alpha) { continuation.yield(line) }
        continuation.finish()

        var session = alphaSession()
        var written = rendered(session.handshake())
        try await CodexWorkerSession.pump(
            lines: lines,
            handle: { line in session.receive(line: line).outgoing },
            write: { written.append($0) }
        )
        #expect(written == Transcript.lines(Transcript.alphaWritten))
    }
}
