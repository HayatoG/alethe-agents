import Foundation

/// When the app may end idle terminals to save memory (upstream `ResourcePolicy`, `resources.rs`).
/// Ending one is a hibernation: its output is kept and it starts again, resuming its agent session,
/// as soon as it is shown.
public struct ResourcePolicy: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Never ends a terminal; memory pressure is only reported (upstream default).
        case manual
        /// Under critical memory pressure, hibernates one idle hidden terminal per check (upstream
        /// `smart-lru`).
        case pressure
        /// Hibernates every hidden terminal idle past its limit, whatever the pressure.
        case idle
    }

    public var mode: Mode
    public var hiddenAgentIdleMinutes: Int
    public var hiddenShellIdleMinutes: Int
    /// A terminal started this recently is never a candidate.
    public var spawnGraceSeconds: Int

    public init(mode: Mode = .manual, hiddenAgentIdleMinutes: Int = 15, hiddenShellIdleMinutes: Int = 30,
                spawnGraceSeconds: Int = 120) {
        self.mode = mode
        self.hiddenAgentIdleMinutes = hiddenAgentIdleMinutes
        self.hiddenShellIdleMinutes = hiddenShellIdleMinutes
        self.spawnGraceSeconds = spawnGraceSeconds
    }

    public static let agentIdleRange = 5...240
    public static let shellIdleRange = 5...480

    /// Values clamped to upstream's ranges.
    public var normalized: ResourcePolicy {
        var result = self
        result.hiddenAgentIdleMinutes = min(max(hiddenAgentIdleMinutes, Self.agentIdleRange.lowerBound), Self.agentIdleRange.upperBound)
        result.hiddenShellIdleMinutes = min(max(hiddenShellIdleMinutes, Self.shellIdleRange.lowerBound), Self.shellIdleRange.upperBound)
        result.spawnGraceSeconds = min(max(spawnGraceSeconds, 30), 900)
        return result
    }
}

/// How short the system is of memory (upstream `pressure_level`).
public enum MemoryPressure: Int, Comparable, Sendable {
    case normal, warning, critical

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    /// From the memory available to apps: critical at 5 % of RAM (at least 512 MB), warning at 10 %
    /// (at least 1 GB), each held until 25 % past its threshold so it does not flap.
    public static func level(availableMB: Double, totalMB: Double, previous: MemoryPressure) -> MemoryPressure {
        let total = max(totalMB, 1)
        let critical = max(total * 0.05, 512)
        let warning = max(total * 0.10, 1024)
        if availableMB <= critical || (previous == .critical && availableMB <= critical * 1.25) { return .critical }
        if availableMB <= warning || (previous == .warning && availableMB <= warning * 1.25) { return .warning }
        return .normal
    }
}

/// What the supervisor knows of one running terminal (upstream `PtyRuntimeMeta`). Times are
/// seconds on any shared clock.
public struct TerminalRuntime: Hashable, Sendable {
    public var tab: TabID
    public var isShell: Bool
    /// On screen, or one switch away (its pane's shown tab in an open container).
    public var isMounted: Bool
    public var isFocused: Bool
    public var lastOutput: TimeInterval
    public var startedAt: TimeInterval
    public var lastUsed: TimeInterval
    public var memoryMB: Double

    public init(tab: TabID, isShell: Bool, isMounted: Bool, isFocused: Bool, lastOutput: TimeInterval,
                startedAt: TimeInterval, lastUsed: TimeInterval, memoryMB: Double) {
        self.tab = tab
        self.isShell = isShell
        self.isMounted = isMounted
        self.isFocused = isFocused
        self.lastOutput = lastOutput
        self.startedAt = startedAt
        self.lastUsed = lastUsed
        self.memoryMB = memoryMB
    }
}

public enum ResourceSupervision {
    /// Whether this check may end a terminal: only when the user opted in (upstream `may_suspend`,
    /// plus the native idle mode).
    public static func mayHibernate(_ level: MemoryPressure, policy: ResourcePolicy) -> Bool {
        switch policy.mode {
        case .manual: false
        case .pressure: level == .critical
        case .idle: true
        }
    }

    /// Terminals that could be hibernated, best first (upstream `eligible_candidates`): never mounted
    /// or focused ones, nor those in their spawn grace or not idle long enough; shells before agents,
    /// then least recently used, then the largest.
    public static func candidates(_ runtimes: [TerminalRuntime], policy: ResourcePolicy, now: TimeInterval) -> [TabID] {
        let policy = policy.normalized
        return runtimes
            .filter { runtime in
                guard !runtime.isMounted, !runtime.isFocused,
                      now - runtime.startedAt >= TimeInterval(policy.spawnGraceSeconds) else { return false }
                let idle = runtime.isShell ? policy.hiddenShellIdleMinutes : policy.hiddenAgentIdleMinutes
                return now - runtime.lastOutput >= TimeInterval(idle * 60)
            }
            .sorted { a, b in
                if a.isShell != b.isShell { return a.isShell }
                if a.lastUsed != b.lastUsed { return a.lastUsed < b.lastUsed }
                return a.memoryMB > b.memoryMB
            }
            .map(\.tab)
    }
}

extension WorkspaceDocument {
    /// Tabs whose terminal the workspace shows or keeps one switch away: the shown tab of every
    /// enabled pane in the shown grid of each container on screen.
    public var mountedTabIDs: Set<TabID> {
        let shown = workspace.fullscreenProjectID.map { [$0] } ?? workspace.openProjectIDs
        return Set(shown.compactMap(project).flatMap(\.visiblePanes).filter { !$0.isDisabled }.compactMap(\.activeTab?.id))
    }
}
