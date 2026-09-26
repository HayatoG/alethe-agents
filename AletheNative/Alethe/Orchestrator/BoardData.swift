import AletheOrchestrator
import Foundation

/// What one board reads: every job (the core's workers and the planners' own subagents), the
/// declared planners, and the project it was opened in.
struct BoardSource: Equatable, Sendable {
    var jobs: [JobSnapshot] = []
    var planners: [Planner] = []
    /// Tab ids of the board's project: a planner id is the tab its agent runs in.
    var projectTabs: Set<String> = []
    /// Tab ids open anywhere in the workspace, to tell a closed planner from another project's.
    var openTabs: Set<String> = []
    var folder: String = ""
}

/// The board's derived state, computed off the main thread.
struct BoardDerived: Sendable {
    var groups: [PlannerGroup] = []
    var activeKey: String?
    var graph: BoardGraph = .empty
    /// Promoted image per job id (its own canvas card).
    var media: [String: MediaItem] = [:]
    var jobsByID: [String: JobSnapshot] = [:]
    /// Every visible job, across planners (the header's totals).
    var visibleJobs: [JobSnapshot] = []
}

enum BoardData {
    /// A planner id is a tab id, never empty, so "" stands for work delegated from outside a terminal.
    static func key(_ group: PlannerGroup) -> String { group.id ?? "" }

    /// Upstream filters the global snapshot to the board's project: a job whose planner is one of
    /// its tabs, or one without a planner that ran inside its folder. A planner whose tab was closed
    /// is kept when its work ran inside the folder, so the board can say the tab is gone.
    static func visibleJobs(_ source: BoardSource) -> [JobSnapshot] {
        source.jobs.filter { job in
            if let planner = job.plannerID {
                if source.projectTabs.contains(planner) { return true }
                return !source.openTabs.contains(planner) && isInside(job.cwd, source.folder)
            }
            return isInside(job.cwd, source.folder)
        }
    }

    static func visiblePlanners(_ source: BoardSource, jobs: [JobSnapshot]) -> [Planner] {
        let referenced = Set(jobs.compactMap(\.plannerID))
        return source.planners.filter { source.projectTabs.contains($0.id) || referenced.contains($0.id) }
    }

    static func derive(_ source: BoardSource, selected: String?, heights: [String: Double]) -> BoardDerived {
        let jobs = visibleJobs(source)
        let groups = PlannerGroup.group(jobs: jobs, planners: visiblePlanners(source, jobs: jobs))
        let active = groups.first { key($0) == selected } ?? groups.first
        let groupJobs = active?.jobs ?? []
        let media = BoardMedia.promotedByJobID(groupJobs)
        let graph = BoardLayout.layout(runs: active?.runs ?? [], heights: heights, plannerID: active?.id, mediaByJobID: media)
        return BoardDerived(
            groups: groups,
            activeKey: active.map(key),
            graph: graph,
            media: media,
            jobsByID: Dictionary(groupJobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            visibleJobs: jobs
        )
    }

    /// The rail's order: runs that need the person first (worst first), then the rest as delegated;
    /// inside a run, workers by lane (`RUN_LANE_ORDER`), keeping their order within a lane.
    static func railRuns(_ runs: [BoardRun]) -> [BoardRun] {
        let attentionRank: (BoardRun) -> Int = { run in
            guard let lane = run.counts.attention?.lane else { return RunAttention.Lane.allCases.count }
            return RunAttention.Lane.allCases.firstIndex(of: lane) ?? 0
        }
        let laneRank = Dictionary(uniqueKeysWithValues: RunLane.allCases.enumerated().map { ($1, $0) })
        return runs.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (attentionRank(lhs.element), attentionRank(rhs.element))
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map { entry in
                var run = entry.element
                run.jobs = run.jobs.enumerated()
                    .sorted { lhs, rhs in
                        let (a, b) = (laneRank[RunLane(lhs.element.status)] ?? 0, laneRank[RunLane(rhs.element.status)] ?? 0)
                        return a == b ? lhs.offset < rhs.offset : a < b
                    }
                    .map(\.element)
                return run
            }
    }

    /// A finished run folds itself away; anything still live or still needing the person opens.
    static func opensByDefault(_ run: BoardRun) -> Bool { run.state != .finished }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        guard !folder.isEmpty, !path.isEmpty else { return false }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }
}
