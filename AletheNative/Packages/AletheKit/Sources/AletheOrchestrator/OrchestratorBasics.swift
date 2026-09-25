import Foundation
import AletheIntegrations

/// Limits and defaults shared by the core, the store and the board (upstream `orchestrator_core.rs`).
public enum OrchestratorLimits {
    public static let defaultConcurrency = 4
    public static let concurrencyRange = 1...16
    /// `alethe_check` never blocks longer than this, whatever the planner asks for.
    public static let maxWaitMs: UInt64 = 600_000
    public static let defaultCheckWaitMs: UInt64 = 300_000
    /// How much of a worker's live reply is kept.
    public static let replyLimit = 16_000
    public static let defaultJobTimeoutMs: UInt64 = 900_000
    /// Finished workers kept alive for follow-ups; older ones are released.
    public static let parkedLimit = 4
    /// How much of a report a snapshot carries.
    public static let summaryLimit = 1200
    /// The first request id a worker's own requests count up from.
    public static let firstRequestID = 10
}

/// Worker backends the core knows by name (a `Launcher.kind` and a `Job.agent`).
public enum WorkerAgent {
    public static let codex = "codex"
    public static let claude = "claude"
}

/// Where a job's state stands (upstream `STATUS_*`).
public enum JobStatus: String, Hashable, Sendable, CaseIterable, Codable {
    case queued
    case running
    /// Holding its slot, but stopped on a question only a person can answer.
    case blocked
    case done
    case failed
    case cancelled
    case released
    /// Its process died with the app; the agent's thread survives on disk, so it can be resumed.
    case interrupted

    /// Nothing more will happen on its own: the worker is finished, let go or gone.
    public var settled: Bool {
        switch self {
        case .done, .failed, .cancelled, .released, .interrupted: true
        case .queued, .running, .blocked: false
        }
    }
}

/// The agent session that called the tools; Alethe registers one per terminal tab.
public struct Planner: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var agent: String

    public init(id: String, label: String, agent: String) {
        self.id = id
        self.label = label
        self.agent = agent
    }

    public var json: OrderedJSON {
        ["id": .string(id), "label": .string(label), "agent": .string(agent)]
    }

    /// A stored planner; the label falls back to the id and the agent to empty, like upstream.
    public init?(json: OrderedJSON) {
        guard let object = json.objectValue, let id = object["id"]?.stringValue else { return nil }
        self.init(id: id, label: object["label"]?.stringValue ?? id, agent: object["agent"]?.stringValue ?? "")
    }
}

/// Something a worker produced for the planner to collect with `alethe_check`.
public struct Delivery: Hashable, Sendable {
    public var sequence: UInt64
    /// Upstream's `type` (for example `result` or `approval`).
    public var kind: String
    public var jobID: String
    public var outcome: String?
    public var text: String

    public init(sequence: UInt64, kind: String, jobID: String, outcome: String?, text: String) {
        self.sequence = sequence
        self.kind = kind
        self.jobID = jobID
        self.outcome = outcome
        self.text = text
    }

    public var json: OrderedJSON {
        [
            "seq": .unsigned(sequence),
            "type": .string(kind),
            "jobId": .string(jobID),
            "outcome": .optional(outcome),
            "text": .string(text),
        ]
    }
}

/// How to start one worker. Resolved once by the app; the core never guesses a path.
public struct Launcher: Hashable, Sendable {
    /// Which CLI this starts (`codex`, `claude`), so the board can say who did the work.
    public var kind: String
    public var program: URL
    public var arguments: [String]
    /// Added on top of the clean worker environment. Never logged: it may carry secrets.
    public var environment: [String: String]

    public init(kind: String, program: URL, arguments: [String], environment: [String: String] = [:]) {
        self.kind = kind
        self.program = program
        self.arguments = arguments
        self.environment = environment
    }
}

/// Job and run ids (`job-07`, `run-03`).
public enum OrchestratorID {
    public static func job(_ number: UInt64) -> String { "job-" + padded(number) }
    public static func run(_ number: UInt64) -> String { "run-" + padded(number) }

    /// `job-07` → 7, so restored ids never collide with new ones; anything else is 0.
    public static func trailingNumber(_ id: String) -> UInt64 {
        let tail = id.split(separator: "-", omittingEmptySubsequences: false).last ?? ""
        return UInt64(tail) ?? 0
    }

    private static func padded(_ number: UInt64) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }
}

/// Keeps the end of a long text: a worker's conclusion is the last thing it says, never the first.
public func orchestratorTail(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = trimmed.unicodeScalars
    guard scalars.count > limit else { return trimmed }
    var result = String.UnicodeScalarView()
    result.append(contentsOf: scalars.suffix(limit))
    return String(result)
}

/// Token counts in the shape the board reads (`totalTokens`, `inputTokens`, …).
public enum TokenCounts {
    public static let keys = ["totalTokens", "inputTokens", "outputTokens", "cachedInputTokens", "cacheCreationInputTokens"]

    /// Claude's `usage` block (snake_case) as a token count; the total includes cache reads and writes.
    public static func claude(usage: OrderedJSON) -> OrderedJSON {
        let input = value(usage, "input_tokens")
        let output = value(usage, "output_tokens")
        let cached = value(usage, "cache_read_input_tokens")
        let cacheCreation = value(usage, "cache_creation_input_tokens")
        let total = input.addingSaturated(output).addingSaturated(cached).addingSaturated(cacheCreation)
        return [
            "totalTokens": .unsigned(total),
            "inputTokens": .unsigned(input),
            "outputTokens": .unsigned(output),
            "cachedInputTokens": .unsigned(cached),
            "cacheCreationInputTokens": .unsigned(cacheCreation),
        ]
    }

    /// Adds a turn's count to a running total, key by key; a missing key counts as zero.
    public static func adding(_ total: OrderedJSON, _ turn: OrderedJSON) -> OrderedJSON {
        .object(OrderedJSONObject(keys.map { key in
            (key, .unsigned(value(total, key).addingSaturated(value(turn, key))))
        }))
    }

    static func value(_ json: OrderedJSON, _ key: String) -> UInt64 {
        json.objectValue?[key]?.uint64Value ?? 0
    }
}

extension UInt64 {
    func addingSaturated(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

extension OrderedJSON {
    static func optional(_ value: String?) -> OrderedJSON { value.map(OrderedJSON.string) ?? .null }
    static func optional(_ value: UInt64?) -> OrderedJSON { value.map(OrderedJSON.unsigned) ?? .null }
    static func optional(_ value: Double?) -> OrderedJSON { value.map(OrderedJSON.double) ?? .null }
    static func optional(_ value: OrderedJSON?) -> OrderedJSON { value ?? .null }

    /// A stored value that is present and not `null`.
    var nonNull: OrderedJSON? {
        if case .null = self { return nil }
        return self
    }
}
