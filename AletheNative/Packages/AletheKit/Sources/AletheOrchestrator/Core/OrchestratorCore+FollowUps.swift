import Foundation
import AletheIntegrations

/// Talking to a worker after delegation (upstream `alethe_steer`, `alethe_send`, `alethe_answer`,
/// `alethe_diff`, `Core::answer`, `Core::job_diff`). Every write to a worker goes through its own
/// line writer, so none of these waits on a worker's pipe.
extension OrchestratorCore {
    func followUpTool(name: String, arguments: OrderedJSONObject) throws(OrchestratorToolError) -> OrderedJSON {
        switch name {
        case "alethe_steer":
            return try steer(job: Self.requiredArgument(arguments, "jobId"), message: Self.requiredArgument(arguments, "message"))
        case "alethe_send":
            return try send(job: Self.requiredArgument(arguments, "jobId"), message: Self.requiredArgument(arguments, "message"))
        case "alethe_answer":
            return try answer(job: Self.requiredArgument(arguments, "jobId"), decision: Self.requiredArgument(arguments, "decision"))
        case "alethe_diff":
            let jobID = try Self.requiredArgument(arguments, "jobId")
            return ["jobId": .string(jobID), "diff": .string(try jobDiff(jobID))]
        default:
            throw OrchestratorToolError("unknown tool \(name)")
        }
    }

    static func requiredArgument(_ arguments: OrderedJSONObject, _ key: String) throws(OrchestratorToolError) -> String {
        guard let value = arguments[key]?.stringValue else { throw OrchestratorToolError("\(key) is required") }
        return value
    }

    func existingJob(_ jobID: String) throws(OrchestratorToolError) -> Job {
        guard let job = jobs[jobID] else { throw OrchestratorToolError("unknown job \(jobID)") }
        return job
    }

    // MARK: alethe_steer

    /// Corrects the running turn, context kept. Codex takes it into the turn (`turn/steer`); Claude
    /// has no mid-turn steer, so its turn is interrupted and the correction starts next. A Claude
    /// worker that is not running a turn takes it as its next one.
    public func steer(job jobID: String, message: String) throws(OrchestratorToolError) -> OrderedJSON {
        var job = try existingJob(jobID)
        guard job.threadID != nil else { throw OrchestratorToolError("job \(jobID) has no thread yet") }
        if job.agent == WorkerAgent.claude {
            let steer = ClaudeWorkerProtocol.steer(&job, message: message, workerIsLive: workers[jobID] != nil)
            jobs[jobID] = job
            if case .interrupt(_, let request) = steer { writeToWorker(jobID, request) }
            notify()
            return steer.result
        }
        guard let turnID = job.activeTurnID else {
            throw OrchestratorToolError("job \(jobID) has no running turn to steer")
        }
        guard var session = workers[jobID]?.codex else { throw OrchestratorToolError("job \(jobID) has no live worker") }
        let request = try session.steer(message)
        workers[jobID]?.codex = session
        syncRequestID(jobID)
        writeToWorker(jobID, request)
        return ["steered": .string(jobID), "turnId": .string(turnID)]
    }

    // MARK: alethe_send

    /// A follow-up on the worker's own thread. A busy worker takes it as its next turn (its inbox),
    /// a parked one at once, and one whose process is gone (released, interrupted, stopped) is
    /// started again on its thread with the message as its first turn.
    public func send(job jobID: String, message: String) throws(OrchestratorToolError) -> OrderedJSON {
        var job = try existingJob(jobID)
        guard let threadID = job.threadID else { throw OrchestratorToolError("job \(jobID) has no thread") }

        // Waiting beats both alternatives: refusing makes the lead babysit the worker, and steering
        // would bend the turn in flight instead of adding to it. A job already queued or spawning
        // picks the message up the same way.
        let live = workers[jobID] != nil || spawning[jobID] != nil
        if (live && !job.settled) || job.status == .queued {
            job.inbox.append(message)
            jobs[jobID] = job
            notify()
            return ["queued": .string(jobID), "waiting": .integer(job.inbox.count)]
        }

        guard live else {
            // Its thread survives on disk, so the worker is started again and picks up from there.
            job.inbox.append(message)
            job.status = .queued
            jobs[jobID] = job
            queue.append(jobID)
            notify()
            persist()
            drainQueue()
            return ["revived": .string(jobID), "resumedThread": .string(threadID), "queued": true]
        }

        guard slots.count < concurrencyLimit else {
            throw OrchestratorToolError("concurrency limit \(concurrencyLimit) reached, call alethe_check first")
        }
        let turn: OrderedJSON
        if job.agent == WorkerAgent.claude {
            // Claude's process is multi-turn: the next user line is the next turn.
            turn = ClaudeWorkerProtocol.userTurn(message)
        } else {
            guard var session = workers[jobID]?.codex else { throw OrchestratorToolError("job \(jobID) has no live worker") }
            turn = try session.startTurn(message)
            workers[jobID]?.codex = session
            job.nextRequestID = session.nextRequestID
        }
        job.status = .running
        job.outcome = nil
        job.endedAt = nil
        job.reply = ""
        job.report = ""
        jobs[jobID] = job
        slots.insert(jobID)
        writeToWorker(jobID, turn)
        notify()
        persist()
        return ["sent": .string(jobID)]
    }

    // MARK: alethe_answer

    /// Answers what the worker is stopped on, on the id it waits for, and lets it carry on. Only
    /// an explicit decision of the planner or the person reaches here; nothing answers by itself.
    public func answer(job jobID: String, decision: CodexApprovalDecision) throws(OrchestratorToolError) -> OrderedJSON {
        var job = try existingJob(jobID)
        guard job.pending != nil else { throw OrchestratorToolError("job \(jobID) is not waiting on anything") }
        guard var session = workers[jobID]?.codex else { throw OrchestratorToolError("job \(jobID) has no live worker") }
        let reply = try session.answer(decision)
        workers[jobID]?.codex = session
        job.pending = nil
        job.status = .running
        jobs[jobID] = job
        writeToWorker(jobID, reply)
        notify()
        persist()
        return ["answered": .string(jobID), "decision": .string(decision.rawValue)]
    }

    /// The tool's form: the decision is checked before the job, as upstream does.
    public func answer(job jobID: String, decision: String) throws(OrchestratorToolError) -> OrderedJSON {
        guard let parsed = CodexApprovalDecision(rawValue: decision) else {
            let names = CodexApprovalDecision.allCases.map(\.rawValue).joined(separator: ", ")
            throw OrchestratorToolError("decision must be one of \(names)")
        }
        return try answer(job: jobID, decision: parsed)
    }

    // MARK: alethe_diff

    /// The worker's unified diff so far (Codex: its `turn/diff/updated` reports; Claude: its
    /// uncommitted changes after a turn). Empty when it has none yet.
    public func jobDiff(_ jobID: String) throws(OrchestratorToolError) -> String {
        try existingJob(jobID).diff ?? ""
    }
}
