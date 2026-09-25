import Foundation
import AletheGit
import AletheIntegrations

/// What one line of a Claude worker's output asks of the core.
public enum ClaudeWorkerEvent: Hashable, Sendable {
    /// Nothing the board shows changed.
    case ignored
    /// The job changed (session id, reply, quota): observers should see it.
    case updated
    /// The turn is over. The core computes the worker's diff (`uncommittedDiff`), then finishes
    /// the turn with this (upstream `finish_turn`), keeping the process parked for follow-ups.
    case turnEnded(ClaudeTurnEnd)
}

/// How a Claude turn ended (the arguments upstream passes to `finish` / `finish_turn`).
public struct ClaudeTurnEnd: Hashable, Sendable {
    public var status: JobStatus
    public var outcome: String?
    public var text: String
    /// False for the `result` that only acknowledges an interrupt this side asked for: nothing was
    /// delivered, so the planner must not be told it was.
    public var announce: Bool

    public init(status: JobStatus, outcome: String?, text: String, announce: Bool) {
        self.status = status
        self.outcome = outcome
        self.text = text
        self.announce = announce
    }
}

/// What steering a Claude worker comes to (upstream `alethe_steer`, Claude branch).
public enum ClaudeSteer: Hashable, Sendable {
    /// The turn is live: write `request` to abort it; the correction leads the inbox and starts as
    /// soon as the aborted `result` arrives.
    case interrupt(jobID: String, request: OrderedJSON)
    /// No turn is running: the correction waits as the worker's next turn.
    case queued(jobID: String, waiting: Int)

    /// The tool's answer, as upstream words it.
    public var result: OrderedJSON {
        switch self {
        case .interrupt(let jobID, _):
            ["steered": .string(jobID)]
        case .queued(let jobID, let waiting):
            [
                "queued": .string(jobID),
                "waiting": .integer(waiting),
                "note": "worker is not running a turn; the steer starts as its next one",
            ]
        }
    }
}

/// Claude Code's headless `stream-json` worker protocol (upstream `on_worker_message_claude` and the
/// Claude branches of spawn, steer, send and cancel), as pure functions over a `Job`. Independent
/// of the process host: lines come in as text, messages to write go out as `OrderedJSON` (one line
/// each, `line(_:)`), so a full pipe never blocks inside the core's isolation.
///
/// There is no handshake: the first user message is the first turn, and every later user message
/// is the next turn on the same session. The stream has no approval channel (the worker runs with
/// `bypassPermissions`), so a denied tool call is reported in the reply, never asked.
public enum ClaudeWorkerProtocol {
    /// The launcher's arguments, plus `--resume <session>` when an interrupted job picks up its own
    /// session (Claude keeps it on disk; there is no resume request like Codex's `thread/resume`).
    public static func arguments(_ launcher: Launcher, resuming sessionID: String?) -> [String] {
        guard let sessionID, !sessionID.isEmpty else { return launcher.arguments }
        return launcher.arguments + ["--resume", sessionID]
    }

    /// One user turn.
    public static func userTurn(_ text: String) -> OrderedJSON {
        [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": .string(text)]],
            ],
        ]
    }

    /// The control request that aborts the running turn; `cancelQueued` also clears the CLI's own
    /// queue, so nothing it holds starts a turn between the abort and the teardown.
    public static func interrupt(requestID: String, cancelQueued: Bool = false) -> OrderedJSON {
        var request: OrderedJSONObject = ["subtype": "interrupt"]
        if cancelQueued { request["cancel_queued"] = .bool(true) }
        return [
            "type": "control_request",
            "request_id": .string(requestID),
            "request": .object(request),
        ]
    }

    /// A message as the line written to the worker's stdin.
    public static func line(_ message: OrderedJSON) -> Data {
        Data((message.compactRendered() + "\n").utf8)
    }

    /// One line of the worker's stdout; blank and invalid lines are skipped (nil).
    public static func parse(line: String) -> OrderedJSON? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? OrderedJSON.parse(trimmed)
    }

    /// The first turn written after spawning: work that arrived while the worker was down leads,
    /// otherwise the task itself.
    public static func firstTurn(_ job: inout Job) -> OrderedJSON {
        userTurn(job.inbox.isEmpty ? job.spec : job.inbox.removeFirst())
    }

    /// The next queued message as a fresh turn on the worker's own session (upstream
    /// `next_from_inbox`); nil without a session or with an empty inbox.
    public static func nextTurn(_ job: inout Job) -> OrderedJSON? {
        guard job.threadID != nil, !job.inbox.isEmpty else { return nil }
        return userTurn(job.inbox.removeFirst())
    }

    /// Applies one stdout message to the job.
    public static func handle(_ message: OrderedJSON, job: inout Job) -> ClaudeWorkerEvent {
        guard let object = message.objectValue else { return .ignored }
        switch object["type"]?.stringValue ?? "" {
        case "rate_limit_event":
            guard let info = object["rate_limit_info"] else { return .ignored }
            job.quota = info
            return .updated

        case "system":
            switch object["subtype"]?.stringValue ?? "" {
            case "init":
                guard let sessionID = object["session_id"]?.stringValue else { return .ignored }
                if job.threadID == nil { job.threadID = sessionID }
                return .updated
            case "permission_denied":
                let note = object["message"]?.stringValue ?? "a tool call was denied permission"
                appendReply("\n[blocked] \(note)\n", to: &job)
                return .updated
            default:
                return .ignored
            }

        case "assistant":
            let blocks = object["message"]?.objectValue?["content"]?.arrayValue ?? []
            let text = blocks
                .filter { $0.objectValue?["type"]?.stringValue == "text" }
                .compactMap { $0.objectValue?["text"]?.stringValue }
                .joined()
            guard !text.isEmpty else { return .ignored }
            appendReply(text, to: &job)
            return .updated

        case "result":
            return .turnEnded(result(object, job: &job))

        default:
            return .ignored
        }
    }

    /// A turn's `result`: usage and cost are counted even for a turn this side aborted.
    private static func result(_ object: OrderedJSONObject, job: inout Job) -> ClaudeTurnEnd {
        let isError = object["is_error"]?.boolValue ?? false
        let resultText = (object["result"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let usage = object["usage"] {
            let last = TokenCounts.claude(usage: usage)
            let current: OrderedJSON? = job.tokens?.objectValue?["total"]
            let total = current.map { TokenCounts.adding($0, last) } ?? last
            job.tokens = ["total": total, "last": last]
        }
        if let cost = object["total_cost_usd"]?.doubleValue, cost.isFinite, cost >= 0 {
            job.costUSD = (job.costUSD ?? 0) + cost
        }
        let summary = resultText.isEmpty
            ? orchestratorTail(job.reply, limit: OrchestratorLimits.replyLimit)
            : resultText
        if job.awaitingSteer {
            job.awaitingSteer = false
            return ClaudeTurnEnd(status: .interrupted, outcome: nil, text: "", announce: false)
        }
        return ClaudeTurnEnd(
            status: isError ? .failed : .done,
            outcome: isError ? "failed" : "succeeded",
            text: summary,
            announce: true
        )
    }

    /// Claude has no mid-turn steer: the only control message that reaches a running turn is
    /// `interrupt`. The correction is queued first and the turn aborted second, which lands the same
    /// way because finishing the aborted turn hands the inbox straight back to the worker. The
    /// caller checks the job has a session before steering (shared with Codex).
    public static func steer(_ job: inout Job, message: String, workerIsLive: Bool) -> ClaudeSteer {
        guard job.status == .running, workerIsLive else {
            job.inbox.append(message)
            return .queued(jobID: job.id, waiting: job.inbox.count)
        }
        job.inbox.insert(message, at: 0)
        job.awaitingSteer = true
        return .interrupt(jobID: job.id, request: interrupt(requestID: nextInterruptID(&job)))
    }

    /// The abort written before a cancelled worker is torn down; its `result` must not count as a
    /// steer.
    public static func cancel(_ job: inout Job) -> OrderedJSON {
        job.awaitingSteer = false
        return interrupt(requestID: nextInterruptID(&job), cancelQueued: true)
    }

    /// The worker's uncommitted `git diff HEAD` in its folder after a turn; nil when there is none
    /// or the folder is not a repository. Runs git: call it outside the core's isolation.
    public static func uncommittedDiff(in cwd: String, runner: GitRunner = GitRunner()) async -> String? {
        let folder = URL(fileURLWithPath: cwd, isDirectory: true)
        guard let output = try? await runner.run(["diff", "--no-color", "--no-ext-diff", "HEAD"], in: folder) else {
            return nil
        }
        let diff = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return diff.isEmpty ? nil : diff
    }

    private static func nextInterruptID(_ job: inout Job) -> String {
        job.nextRequestID += 1
        return "\(job.id)-interrupt-\(job.nextRequestID)"
    }

    /// Only the end of the live reply is kept.
    private static func appendReply(_ text: String, to job: inout Job) {
        job.reply += text
        let scalars = job.reply.unicodeScalars
        guard scalars.count > OrchestratorLimits.replyLimit else { return }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars.suffix(OrchestratorLimits.replyLimit))
        job.reply = String(kept)
    }
}
