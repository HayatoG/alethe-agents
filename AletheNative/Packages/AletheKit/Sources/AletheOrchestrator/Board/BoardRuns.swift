import Foundation
import AletheIntegrations

/// The column a worker sits in on the board (upstream `lib/orchestratorRuns.ts`). Declared in the
/// board's lane order: `allCases` is `RUN_LANE_ORDER`.
public enum RunLane: String, Hashable, Sendable, CaseIterable {
    case blocked
    case running
    case queued
    case interrupted
    case failed
    case finished

    /// Upstream `LANE_OF`: every settled-for-good status reads as finished.
    public init(_ status: JobStatus) {
        switch status {
        case .blocked: self = .blocked
        case .running: self = .running
        case .queued: self = .queued
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        case .done, .cancelled, .released: self = .finished
        }
    }

    // Worst-first: a blocked worker leads because it is stopped on a person and still holds its
    // slot, a failure outranks live workers, and interrupted work outranks them too because only the
    // user can bring it back.
    static let statePriority: [RunLane] = [.blocked, .failed, .interrupted, .running, .queued, .finished]
}

/// How many workers sit in each lane.
public struct RunCounts: Hashable, Sendable {
    public private(set) var values: [RunLane: Int]

    public init(_ values: [RunLane: Int] = [:]) {
        self.values = values.filter { $0.value != 0 }
    }

    /// Upstream `countLanes`.
    public init(jobs: some Sequence<JobSnapshot>) {
        var counts = RunCounts()
        for job in jobs { counts[RunLane(job.status)] += 1 }
        self = counts
    }

    public subscript(lane: RunLane) -> Int {
        get { values[lane] ?? 0 }
        set { values[lane] = newValue == 0 ? nil : newValue }
    }

    public var total: Int { values.values.reduce(0, +) }

    /// Upstream `worstState`: the worst lane anything is in, finished when empty.
    public var worstState: RunLane {
        RunLane.statePriority.first { self[$0] > 0 } ?? .finished
    }

    /// Upstream `attentionOf`: what waits on the user, or nil when nothing does.
    public var attention: RunAttention? {
        RunAttention.Lane.allCases.first { self[$0.runLane] > 0 }.map { RunAttention(lane: $0, count: self[$0.runLane]) }
    }
}

/// Work only a person can clear, worst lane first.
public struct RunAttention: Hashable, Sendable {
    /// Declared worst first: blocked still costs a slot, a failure is already over.
    public enum Lane: String, Hashable, Sendable, CaseIterable {
        case blocked
        case failed
        case interrupted

        public var runLane: RunLane {
            switch self {
            case .blocked: .blocked
            case .failed: .failed
            case .interrupted: .interrupted
            }
        }
    }

    public var lane: Lane
    public var count: Int

    public init(lane: Lane, count: Int) {
        self.lane = lane
        self.count = count
    }
}

/// One delegate call's workers (upstream `OrchestratorRun`).
public struct BoardRun: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var jobs: [JobSnapshot]
    public var counts: RunCounts
    public var state: RunLane

    public init(id: String, label: String, jobs: [JobSnapshot]) {
        self.id = id
        self.label = label
        self.jobs = jobs
        counts = RunCounts(jobs: jobs)
        state = counts.worstState
    }

    /// Upstream `groupRuns`: by run id in first-seen order; the label is the first non-blank one.
    public static func group(_ jobs: [JobSnapshot]) -> [BoardRun] {
        var order: [String] = []
        var grouped: [String: [JobSnapshot]] = [:]
        for job in jobs {
            if grouped[job.runID] == nil { order.append(job.runID) }
            grouped[job.runID, default: []].append(job)
        }
        return order.map { runID in
            let runJobs = grouped[runID] ?? []
            let label = runJobs.lazy.compactMap { cleaned($0.runLabel) }.first
            return BoardRun(id: runID, label: label ?? runID, jobs: runJobs)
        }
    }
}

/// A tab on the board: the terminal that asked for the work, with every run it started (upstream
/// `PlannerGroup`). `id`, `label` and `agent` are nil for work delegated from outside a terminal.
public struct PlannerGroup: Hashable, Sendable {
    public var id: String?
    public var label: String?
    public var agent: String?
    public var runs: [BoardRun]
    public var jobs: [JobSnapshot]
    public var counts: RunCounts
    public var state: RunLane

    public init(id: String?, label: String?, agent: String?, jobs: [JobSnapshot]) {
        self.id = id
        self.label = label
        self.agent = agent
        self.jobs = jobs
        runs = BoardRun.group(jobs)
        counts = RunCounts(jobs: jobs)
        state = counts.worstState
    }

    /// Upstream `groupPlanners`: one group per declared planner (sorted by label, then id, so the tab
    /// strip never reshuffles between snapshots), then one per planner id seen on a job but no longer
    /// declared, in first-seen order, then one last group for jobs that carry no planner.
    public static func group(jobs: [JobSnapshot], planners: [Planner]) -> [PlannerGroup] {
        var order: [String?] = []
        var buckets: [String?: [JobSnapshot]] = [:]
        for job in jobs {
            if buckets[job.plannerID] == nil { order.append(job.plannerID) }
            buckets[job.plannerID, default: []].append(job)
        }

        let declared = planners.sorted { lhs, rhs in
            let byLabel = collate(lhs.label, rhs.label)
            return byLabel == .orderedSame ? collate(lhs.id, rhs.id) == .orderedAscending : byLabel == .orderedAscending
        }
        var groups = declared.map { planner in
            PlannerGroup(
                id: planner.id,
                label: cleaned(planner.label) ?? planner.id,
                agent: cleaned(planner.agent),
                jobs: buckets[planner.id] ?? []
            )
        }

        let known = Set(planners.map(\.id))
        for case let key? in order where !known.contains(key) {
            groups.append(PlannerGroup(id: key, label: key, agent: nil, jobs: buckets[key] ?? []))
        }
        if let orphans = buckets[nil] {
            groups.append(PlannerGroup(id: nil, label: nil, agent: nil, jobs: orphans))
        }
        return groups
    }

    // A fixed collation stands in for `localeCompare`, so the order never depends on the user's locale.
    private static func collate(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Session spend for one worker provider (upstream `AgentSpend`).
public struct AgentSpend: Hashable, Sendable {
    public var agent: String
    public var totalTokens: Double
    public var costUSD: Double
    public var pricedWorkers: Int
    public var unpricedWorkers: Int

    public init(agent: String, totalTokens: Double = 0, costUSD: Double = 0, pricedWorkers: Int = 0, unpricedWorkers: Int = 0) {
        self.agent = agent
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.pricedWorkers = pricedWorkers
        self.unpricedWorkers = unpricedWorkers
    }

    /// Upstream `aggregateAgentSpend`: per provider in first-seen order, skipping workers that have
    /// reported neither tokens nor a price yet.
    public static func aggregate(_ jobs: [JobSnapshot]) -> [AgentSpend] {
        var order: [String] = []
        var byAgent: [String: AgentSpend] = [:]
        for job in jobs {
            let totalTokens = BoardFormat.totalTokens(job) ?? 0
            if totalTokens <= 0 && job.costUSD == nil { continue }
            var current = byAgent[job.agent] ?? AgentSpend(agent: job.agent)
            if byAgent[job.agent] == nil { order.append(job.agent) }
            current.totalTokens += totalTokens
            if let cost = job.costUSD {
                current.costUSD += cost
                current.pricedWorkers += 1
            } else {
                current.unpricedWorkers += 1
            }
            byAgent[job.agent] = current
        }
        return order.compactMap { byAgent[$0] }
    }
}

func cleaned(_ value: String?) -> String? {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
