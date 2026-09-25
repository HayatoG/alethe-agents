/// Commit-graph lane layout, ported from upstream `buildGraphRows` (src/plugins/git-control/GitGraphList.tsx).
///
/// Commits are laid out newest first, as `git log` returns them. Each row places the commit on a lane,
/// continues the first parent on that same lane and opens a new lane for every other parent. Lane colors
/// are a round-robin ordinal per identity (branch name for tips, else the hash that opened the lane);
/// the UI maps `colorIndex % palette.count` and paints lane 0 with the fixed "main" color.

/// A line segment inside one row half: `from` lane at the half's top → `to` lane at its bottom.
/// `from == to` is a straight line; otherwise it is a curve (convergence, branch or merge).
public struct GitGraphEdge: Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var colorIndex: Int

    public init(from: Int, to: Int, colorIndex: Int) {
        self.from = from
        self.to = to
        self.colorIndex = colorIndex
    }
}

public struct GitGraphRow: Hashable, Sendable, Identifiable {
    public var commit: GitCommit
    /// Lane holding this commit's node.
    public var lane: Int
    /// Color ordinal of the commit's own lane.
    public var colorIndex: Int
    /// Lane occupancy (the hash each lane waits for) entering and leaving the row.
    public var lanesBefore: [String?]
    public var lanesAfter: [String?]
    /// Top half (row top → node center): pass-throughs, the commit lane and lanes converging on the node.
    public var topEdges: [GitGraphEdge]
    /// Bottom half (node center → row bottom): the commit lane, pass-throughs and branch/merge curves.
    public var bottomEdges: [GitGraphEdge]
    public var isLastRow: Bool

    public var id: String { commit.hash }
    public var refs: [GitRef] { commit.refs }
    /// Lanes needed to draw this row.
    public var laneCount: Int { max(lanesBefore.count, lanesAfter.count, lane + 1) }
    /// Lanes that run straight through the row without touching the node.
    public var passThroughLanes: [Int] {
        topEdges.filter { $0.from == $0.to && $0.from != lane }.map(\.from)
    }
}

/// Incremental layout: feed pages in order with `append`; open lanes carry across pages, so paginated
/// output equals a one-shot layout of the concatenated commits.
public struct GitGraphLayout: Sendable {
    private var lanes: [String?] = []
    private var laneColors: [Int?] = []
    private var seen: Set<String> = []
    private var colorByIdentity: [String: Int] = [:]
    private var nextColor = 0
    private var branchByHash: [String: String] = [:]

    public init() {}

    /// One-shot layout of a complete window (upstream semantics: parents outside it end their lane).
    public static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var layout = GitGraphLayout()
        return layout.append(commits, hasMore: false)
    }

    /// Lanes still waiting for a commit that has not been laid out yet.
    public var openLanes: [String?] { lanes }

    /// Lays out the next page. With `hasMore`, parents not seen yet keep their lane open for the next
    /// page; without it, the page is the final one and missing parents end their lane like upstream.
    public mutating func append(_ commits: [GitCommit], hasMore: Bool) -> [GitGraphRow] {
        for commit in commits where branchByHash[commit.hash] == nil {
            if let name = Self.branchName(commit.refs) { branchByHash[commit.hash] = name }
        }
        var remaining = Set(commits.map(\.hash))
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for (index, commit) in commits.enumerated() {
            remaining.remove(commit.hash)
            seen.insert(commit.hash)
            let lanesBefore = lanes
            let colorsBefore = laneColors

            var lane = lanes.firstIndex(of: commit.hash) ?? -1
            if lane == -1 {
                lane = freeLane()
                laneColors[lane] = color(for: commit.hash)
            }
            let colorIndex = laneColors[lane] ?? color(for: commit.hash)

            for l in lanes.indices where lanes[l] == commit.hash { lanes[l] = nil }

            // Merge parents that already own a lane: upstream draws nothing for them; we add a curve.
            var joins: [Int] = []
            if let first = commit.parents.first {
                lanes[lane] = keeps(first, remaining, hasMore) ? first : nil
                for parent in commit.parents.dropFirst() where keeps(parent, remaining, hasMore) {
                    if let existing = lanes.firstIndex(of: parent) {
                        if existing != lane { joins.append(existing) }
                    } else {
                        let l = freeLane()
                        lanes[l] = parent
                        laneColors[l] = color(for: parent)
                    }
                }
            } else {
                lanes[lane] = nil
            }

            let isLastRow = !hasMore && index == commits.count - 1
            let lanesAfter: [String?] = isLastRow ? lanes.map { _ in nil } : lanes

            var top: [GitGraphEdge] = []
            for (l, hash) in lanesBefore.enumerated() {
                guard let hash else { continue }
                let c = colorsBefore[l] ?? 0
                if l == lane || hash == commit.hash {
                    top.append(GitGraphEdge(from: l, to: lane, colorIndex: c))
                } else {
                    top.append(GitGraphEdge(from: l, to: l, colorIndex: c))
                }
            }
            var bottom: [GitGraphEdge] = []
            for (l, parent) in lanesAfter.enumerated() {
                guard let parent else { continue }
                let c = laneColors[l] ?? 0
                if l == lane {
                    bottom.append(GitGraphEdge(from: lane, to: lane, colorIndex: c))
                } else if l < lanesBefore.count, lanesBefore[l] == parent {
                    bottom.append(GitGraphEdge(from: l, to: l, colorIndex: c))
                } else {
                    bottom.append(GitGraphEdge(from: lane, to: l, colorIndex: c))
                }
            }
            if !isLastRow {
                for l in joins where !bottom.contains(where: { $0.from == lane && $0.to == l }) {
                    bottom.append(GitGraphEdge(from: lane, to: l, colorIndex: laneColors[l] ?? 0))
                }
            }

            rows.append(GitGraphRow(
                commit: commit, lane: lane, colorIndex: colorIndex,
                lanesBefore: lanesBefore, lanesAfter: lanesAfter,
                topEdges: top, bottomEdges: bottom, isLastRow: isLastRow
            ))
        }
        if !hasMore {
            lanes = lanes.map { _ in nil }
        }
        return rows
    }

    private func keeps(_ parent: String, _ remaining: Set<String>, _ hasMore: Bool) -> Bool {
        remaining.contains(parent) || (hasMore && !seen.contains(parent))
    }

    private mutating func freeLane() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        laneColors.append(nil)
        return lanes.count - 1
    }

    /// Round-robin color per identity; an identity keeps its ordinal when it reappears.
    private mutating func color(for hash: String) -> Int {
        let identity = branchByHash[hash] ?? hash
        if let cached = colorByIdentity[identity] { return cached }
        let assigned = nextColor
        nextColor += 1
        colorByIdentity[identity] = assigned
        return assigned
    }

    /// Best branch name for coloring a tip: local over `origin/*`, `origin/x` collapsed into `x`, tags ignored.
    static func branchName(_ refs: [GitRef]) -> String? {
        var best: String?
        var bestIsLocal = false
        for ref in refs where ref.kind != .tag {
            let raw = ref.name
            guard !raw.isEmpty else { continue }
            let isLocal = !raw.hasPrefix("origin/")
            let name = isLocal ? raw : String(raw.dropFirst("origin/".count))
            if best == nil || (isLocal && !bestIsLocal) {
                best = name
                bestIsLocal = isLocal
            }
        }
        return best
    }
}
