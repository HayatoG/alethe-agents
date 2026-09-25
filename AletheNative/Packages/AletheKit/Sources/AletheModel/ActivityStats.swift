import Foundation

/// One tick of the activity tracker (upstream `ActivitySample`): how long, whether Alethe was in
/// front and the user was active, what they had in front, and what every agent was doing.
public struct ActivitySample: Hashable, Sendable {
    public struct Agent: Hashable, Sendable {
        public var agent: String
        public var projectID: String?
        public var terminalID: String?
        public var working: Bool

        public init(agent: String, projectID: String?, terminalID: String?, working: Bool) {
            self.agent = agent
            self.projectID = projectID
            self.terminalID = terminalID
            self.working = working
        }
    }

    /// Local day, `yyyy-MM-dd`.
    public var date: String
    public var durationMS: UInt64
    public var appFocused: Bool
    public var userActive: Bool
    public var activeProjectID: String?
    public var activeTerminalID: String?
    public var agents: [Agent]

    public init(date: String, durationMS: UInt64, appFocused: Bool, userActive: Bool, activeProjectID: String? = nil,
                activeTerminalID: String? = nil, agents: [Agent] = []) {
        self.date = date
        self.durationMS = durationMS
        self.appFocused = appFocused
        self.userActive = userActive
        self.activeProjectID = activeProjectID
        self.activeTerminalID = activeTerminalID
        self.agents = agents
    }
}

public struct TimeTotals: Codable, Hashable, Sendable {
    public var appOpenMs: UInt64 = 0
    public var appFocusedMs: UInt64 = 0
    public var userActiveMs: UInt64 = 0
    public var userIdleMs: UInt64 = 0
    /// Wall-clock time with at least one agent working.
    public var agentWallMs: UInt64 = 0
    /// Agent time added up (two agents for a minute count two).
    public var agentSumMs: UInt64 = 0
    /// Agent work the user was not looking at.
    public var agentBackgroundMs: UInt64 = 0
    /// Time with two or more agents working.
    public var parallelMs: UInt64 = 0
    public var peakConcurrent: UInt32 = 0

    public init() {}

    mutating func add(_ other: TimeTotals) {
        appOpenMs += other.appOpenMs
        appFocusedMs += other.appFocusedMs
        userActiveMs += other.userActiveMs
        userIdleMs += other.userIdleMs
        agentWallMs += other.agentWallMs
        agentSumMs += other.agentSumMs
        agentBackgroundMs += other.agentBackgroundMs
        parallelMs += other.parallelMs
        peakConcurrent = max(peakConcurrent, other.peakConcurrent)
    }
}

public struct AgentTotals: Codable, Hashable, Sendable {
    public var workingMs: UInt64 = 0
    public var waitingMs: UInt64 = 0
    public var focusedMs: UInt64 = 0
    public var backgroundMs: UInt64 = 0

    public init() {}

    mutating func add(_ other: AgentTotals) {
        workingMs += other.workingMs
        waitingMs += other.waitingMs
        focusedMs += other.focusedMs
        backgroundMs += other.backgroundMs
    }
}

public struct ProjectTotals: Codable, Hashable, Sendable {
    public var focusedMs: UInt64 = 0
    public var activeMs: UInt64 = 0
    public var idleMs: UInt64 = 0
    public var agentWallMs: UInt64 = 0
    public var agentSumMs: UInt64 = 0
    public var agentBackgroundMs: UInt64 = 0
    public var parallelMs: UInt64 = 0

    public init() {}

    mutating func add(_ other: ProjectTotals) {
        focusedMs += other.focusedMs
        activeMs += other.activeMs
        idleMs += other.idleMs
        agentWallMs += other.agentWallMs
        agentSumMs += other.agentSumMs
        agentBackgroundMs += other.agentBackgroundMs
        parallelMs += other.parallelMs
    }
}

/// A day's totals, and a summary over several days (upstream `DayStats` / `ActivitySummary`).
public struct ActivityTotals: Codable, Hashable, Sendable {
    public var totals = TimeTotals()
    public var agents: [String: AgentTotals] = [:]
    public var projects: [String: ProjectTotals] = [:]

    public init() {}

    public mutating func add(_ other: ActivityTotals) {
        totals.add(other.totals)
        for (key, value) in other.agents { agents[key, default: AgentTotals()].add(value) }
        for (key, value) in other.projects { projects[key, default: ProjectTotals()].add(value) }
    }

    /// Adds one sample (upstream `apply_sample`); a sample never counts more than 15 s.
    public mutating func apply(_ sample: ActivitySample) {
        let duration = min(sample.durationMS, ActivityStats.maximumSampleMS)
        guard duration > 0 else { return }
        totals.appOpenMs += duration
        if sample.appFocused {
            totals.appFocusedMs += duration
            if sample.userActive { totals.userActiveMs += duration } else { totals.userIdleMs += duration }
            if let project = sample.activeProjectID {
                projects[project, default: ProjectTotals()].focusedMs += duration
                if sample.userActive { projects[project]!.activeMs += duration } else { projects[project]!.idleMs += duration }
            }
        }

        let working = sample.agents.filter(\.working)
        if !working.isEmpty { totals.agentWallMs += duration }
        totals.agentSumMs += duration * UInt64(working.count)
        totals.peakConcurrent = max(totals.peakConcurrent, UInt32(working.count))
        if working.count >= 2 { totals.parallelMs += duration }
        if working.contains(where: { !sample.appFocused || $0.projectID != sample.activeProjectID }) {
            totals.agentBackgroundMs += duration
        }

        for agent in sample.agents {
            var entry = agents[agent.agent] ?? AgentTotals()
            if agent.working {
                entry.workingMs += duration
                if sample.appFocused && agent.terminalID == sample.activeTerminalID {
                    entry.focusedMs += duration
                } else {
                    entry.backgroundMs += duration
                }
            } else {
                entry.waitingMs += duration
            }
            agents[agent.agent] = entry
        }

        let counts = Dictionary(grouping: working) { $0.projectID ?? ActivityStats.unassigned }.mapValues(\.count)
        for (project, count) in counts {
            var entry = projects[project] ?? ProjectTotals()
            entry.agentWallMs += duration
            entry.agentSumMs += duration * UInt64(count)
            if count >= 2 { entry.parallelMs += duration }
            if !sample.appFocused || sample.activeProjectID != project { entry.agentBackgroundMs += duration }
            projects[project] = entry
        }
    }
}

/// `activity-stats.json` (upstream `ActivityStatsFile`, version 1): totals per local day.
public struct ActivityStats: Codable, Hashable, Sendable {
    public static let maximumSampleMS: UInt64 = 15_000
    public static let unassigned = "__unassigned__"

    public var version = 1
    public var days: [String: ActivityTotals] = [:]

    public init() {}

    public mutating func record(_ samples: [ActivitySample]) {
        for sample in samples where sample.date.count == 10 {
            days[sample.date, default: ActivityTotals()].apply(sample)
        }
    }

    /// Totals over `dates` (every day when empty).
    public func summary(dates: [String] = []) -> ActivityTotals {
        let filter = Set(dates)
        var summary = ActivityTotals()
        for (date, day) in days where filter.isEmpty || filter.contains(date) { summary.add(day) }
        return summary
    }

    /// `yyyy-MM-dd` in the current calendar and time zone.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The last `count` days ending today, oldest first.
    public static func lastDays(_ count: Int, until now: Date = Date(), calendar: Calendar = .current) -> [String] {
        (0..<max(count, 0)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map { day($0, calendar: calendar) }
    }

    // MARK: - File

    /// Reads the file; a missing one is empty, an unknown version is an error (left untouched).
    public static func load(from url: URL) throws -> ActivityStats {
        guard let data = try? Data(contentsOf: url) else { return ActivityStats() }
        let stats = try JSONDecoder().decode(ActivityStats.self, from: data)
        guard stats.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return stats
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Adds samples to the file (read, add, atomic write).
    public static func append(_ samples: [ActivitySample], to url: URL) throws {
        guard !samples.isEmpty else { return }
        var stats = try load(from: url)
        stats.record(samples)
        try stats.save(to: url)
    }
}
