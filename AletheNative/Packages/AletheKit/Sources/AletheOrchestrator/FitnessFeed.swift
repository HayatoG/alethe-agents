import Foundation
import AletheAgents

/// A board header's quota warning chip for one agent (upstream `useOrchestratorQuotaWarnings`'s
/// `QuotaWarning`): shown at `AgentFitness.headroomThreshold` or when rate-limited, the same line
/// the planner's `headroomHint` uses, so the person and the planner never disagree.
public struct QuotaWarning: Hashable, Sendable {
    public var agent: String
    public var used: Int
    public var resetsAt: Date?
    public var rateLimited: Bool

    public init(agent: String, used: Int, resetsAt: Date? = nil, rateLimited: Bool = false) {
        self.agent = agent
        self.used = used
        self.resetsAt = resetsAt
        self.rateLimited = rateLimited
    }

    /// Nil while the agent still has headroom.
    public init?(agent: String, fitness: AgentFitness) {
        guard fitness.isStrained else { return nil }
        self.init(agent: agent, used: fitness.used, resetsAt: fitness.resetsAt, rateLimited: fitness.rateLimited)
    }

    /// One chip per strained agent, by agent name (Claude before Codex, as upstream checks them).
    public static func warnings(_ readings: [String: AgentFitness]) -> [QuotaWarning] {
        FitnessRouting(readings).entries.compactMap { QuotaWarning(agent: $0.agent, fitness: $0.fitness) }
    }

    /// Time left until the window resets (upstream `formatReset`): `2h5m`, or `5m` under an hour;
    /// nil once it is due, which the chip says as "now".
    public static func countdown(to resetsAt: Date, now: Date = Date()) -> String? {
        let milliseconds = (resetsAt.timeIntervalSince(now) * 1000).rounded(.down)
        guard milliseconds > 0 else { return nil }
        let hours = Int(milliseconds / 3_600_000)
        let minutes = Int(milliseconds.truncatingRemainder(dividingBy: 3_600_000) / 60_000)
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }
}

/// While at least one board is open, reads the planner agents' usage every `interval` (upstream
/// `USAGE_POLL_MS`), pushes each reading into the core as fitness and publishes the quota
/// warnings, so the planner and the person read the same numbers. The last board to close stops
/// the loop. Runs on this actor, off the main thread; `read` owns how usage is fetched.
public actor FitnessFeed {
    public typealias Read = @Sendable () async -> [ProviderUsage]
    public typealias Push = @Sendable (_ agent: String, _ fitness: AgentFitness) async -> Void
    public typealias Publish = @Sendable ([QuotaWarning]) async -> Void

    public static let defaultInterval: Duration = .seconds(60)

    private let interval: Duration
    private let read: Read
    private let push: Push
    private let publish: Publish
    private var boards: Set<UUID> = []
    private var loop: Task<Void, Never>?
    /// The last good reading per agent: a failed read keeps it, as the core does.
    private var readings: [String: AgentFitness] = [:]

    public init(interval: Duration = FitnessFeed.defaultInterval, read: @escaping Read,
                push: @escaping Push, publish: @escaping Publish) {
        self.interval = interval
        self.read = read
        self.push = push
        self.publish = publish
    }

    public var isRunning: Bool { loop != nil }
    public var openBoards: Int { boards.count }

    /// A board appeared; the first one starts the loop, which reads right away.
    public func open(_ board: UUID) {
        boards.insert(board)
        guard loop == nil else { return }
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// A board went away; with none left the loop stops.
    public func close(_ board: UUID) {
        boards.remove(board)
        guard boards.isEmpty else { return }
        loop?.cancel()
        loop = nil
    }

    func tick() async {
        let usages = await read()
        guard !Task.isCancelled else { return }
        for usage in usages {
            guard let fitness = AgentFitness(usage) else { continue }
            readings[usage.agent.rawValue] = fitness
            await push(usage.agent.rawValue, fitness)
        }
        await publish(QuotaWarning.warnings(readings))
    }
}
