import Foundation
import Testing
@testable import AletheGit

private func commit(_ hash: String, _ parents: [String], refs: [GitRef] = []) -> GitCommit {
    GitCommit(hash: hash, parents: parents, refs: refs, authorName: "a", authorEmail: "a@x",
              date: Date(timeIntervalSince1970: 0), subject: hash)
}

private func e(_ from: Int, _ to: Int, _ color: Int) -> GitGraphEdge {
    GitGraphEdge(from: from, to: to, colorIndex: color)
}

/// Goldens were derived by tracing upstream `buildGraphRows` + `GraphRowView` over the same fixtures.
@Suite struct GitGraphLayoutTests {
    let branchMerge = [
        commit("M", ["B1", "F1"], refs: [GitRef(kind: .branch, name: "main", isCurrent: true)]),
        commit("F1", ["B0"], refs: [GitRef(kind: .branch, name: "feature")]),
        commit("B1", ["B0"]),
        commit("B0", []),
    ]
    let octopus = [
        commit("O", ["A", "B", "C"]),
        commit("C", ["R"]),
        commit("B", ["R"]),
        commit("A", ["R"], refs: [GitRef(kind: .tag, name: "v1")]),
        commit("R", []),
    ]

    @Test func linearHistoryStaysOnLaneZero() {
        let rows = GitGraphLayout.layout([commit("A", ["B"]), commit("B", ["C"]), commit("C", [])])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.colorIndex) == [0, 0, 0])
        #expect(rows[0].topEdges.isEmpty)
        #expect(rows[0].bottomEdges == [e(0, 0, 0)])
        #expect(rows[1].topEdges == [e(0, 0, 0)])
        #expect(rows[1].bottomEdges == [e(0, 0, 0)])
        #expect(rows[2].topEdges == [e(0, 0, 0)])
        #expect(rows[2].bottomEdges.isEmpty)
        #expect(rows[2].isLastRow)
        #expect(rows[2].lanesAfter == [nil])
    }

    @Test func branchAndMergeGolden() {
        let rows = GitGraphLayout.layout(branchMerge)
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows.map(\.colorIndex) == [0, 1, 0, 0])
        #expect(rows[0].lanesAfter == ["B1", "F1"])
        #expect(rows[0].bottomEdges == [e(0, 0, 0), e(0, 1, 1)])
        #expect(rows[1].topEdges == [e(0, 0, 0), e(1, 1, 1)])
        #expect(rows[1].bottomEdges == [e(0, 0, 0), e(1, 1, 1)])
        #expect(rows[1].passThroughLanes == [0])
        #expect(rows[2].lanesAfter == ["B0", "B0"])
        #expect(rows[2].bottomEdges == [e(0, 0, 0), e(1, 1, 1)])
        // Root: lane 1 converges into the node on lane 0.
        #expect(rows[3].topEdges == [e(0, 0, 0), e(1, 0, 1)])
        #expect(rows[3].bottomEdges.isEmpty)
        #expect(rows[0].refs.first?.name == "main")
        #expect(rows[0].refs.first?.isCurrent == true)
        #expect(rows.map(\.laneCount) == [2, 2, 2, 2])
    }

    @Test func octopusMergeOpensOneLanePerExtraParent() {
        let rows = GitGraphLayout.layout(octopus)
        #expect(rows.map(\.lane) == [0, 2, 1, 0, 0])
        #expect(rows.map(\.colorIndex) == [0, 2, 1, 0, 0])
        #expect(rows[0].bottomEdges == [e(0, 0, 0), e(0, 1, 1), e(0, 2, 2)])
        #expect(rows[1].lanesAfter == ["A", "B", "R"])
        #expect(rows[1].bottomEdges == [e(0, 0, 0), e(1, 1, 1), e(2, 2, 2)])
        #expect(rows[2].topEdges == [e(0, 0, 0), e(1, 1, 1), e(2, 2, 2)])
        #expect(rows[3].lanesAfter == ["R", "R", "R"])
        #expect(rows[4].topEdges == [e(0, 0, 0), e(1, 0, 1), e(2, 0, 2)])
        #expect(rows[3].refs.map(\.kind) == [.tag])
    }

    @Test func independentRootsGetSeparateLanes() {
        let rows = GitGraphLayout.layout([
            commit("X1", ["X0"]), commit("Y1", ["Y0"]), commit("X0", []), commit("Y0", []),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0, 1])
        #expect(rows.map(\.colorIndex) == [0, 1, 0, 1])
        #expect(rows[1].topEdges == [e(0, 0, 0)])
        #expect(rows[1].bottomEdges == [e(0, 0, 0), e(1, 1, 1)])
        #expect(rows[2].lanesAfter == [nil, "Y0"])
        #expect(rows[2].bottomEdges == [e(1, 1, 1)])
        #expect(rows[3].lanesBefore == [nil, "Y0"])
        #expect(rows[3].topEdges == [e(1, 1, 1)])
    }

    @Test func freedLaneIsReusedByTheNextNewLane() {
        let rows = GitGraphLayout.layout([
            commit("X1", ["X0"]), commit("Y1", ["Y0"]), commit("X0", []), commit("Z1", ["Y0"]), commit("Y0", []),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0, 0, 0])
        #expect(rows[3].colorIndex == 2)
    }

    @Test func mergeIntoAlreadyOpenLaneAddsJoinCurve() {
        let rows = GitGraphLayout.layout([
            commit("H1", ["H2", "S"]), commit("H2", ["H3", "S"]), commit("S", ["H3"]), commit("H3", []),
        ])
        #expect(rows[1].lanesAfter == ["H3", "S"])
        // Upstream draws only the first two; the join curve (0 -> 1) is our addition.
        #expect(rows[1].bottomEdges == [e(0, 0, 0), e(1, 1, 1), e(0, 1, 1)])
    }

    @Test func parentsOutsideTheWindowEndTheirLane() {
        let rows = GitGraphLayout.layout([commit("A", ["B"]), commit("B", ["gone"])])
        #expect(rows[0].lanesAfter == ["B"])
        #expect(rows[1].lanesAfter == [nil])
    }

    @Test func openLanesCarryAcrossPages() {
        var layout = GitGraphLayout()
        let first = layout.append([commit("A", ["B", "C"])], hasMore: true)
        #expect(first[0].lanesAfter == ["B", "C"])
        #expect(!first[0].isLastRow)
        #expect(layout.openLanes == ["B", "C"])
    }

    @Test(arguments: [0, 1])
    func paginationMatchesOneShot(fixture: Int) {
        let commits = fixture == 0 ? branchMerge : octopus
        let expected = GitGraphLayout.layout(commits)
        for split in 1..<commits.count {
            var layout = GitGraphLayout()
            let paged = layout.append(Array(commits[..<split]), hasMore: true)
                + layout.append(Array(commits[split...]), hasMore: false)
            #expect(paged == expected, "split at \(split)")
        }
        var layout = GitGraphLayout()
        let single = commits.indices.flatMap { i in
            layout.append([commits[i]], hasMore: i < commits.count - 1)
        }
        #expect(single == expected)
    }

    @Test func branchNamePrefersLocalAndCollapsesOrigin() {
        #expect(GitGraphLayout.branchName([
            GitRef(kind: .remoteBranch, name: "origin/feat"), GitRef(kind: .branch, name: "feat2"),
        ]) == "feat2")
        #expect(GitGraphLayout.branchName([GitRef(kind: .remoteBranch, name: "origin/main")]) == "main")
        #expect(GitGraphLayout.branchName([GitRef(kind: .tag, name: "v1")]) == nil)
    }

    @Test func sameBranchIdentityKeepsItsColor() {
        // `origin/main` and `main` collapse into one identity, so both lanes share color 0.
        let rows = GitGraphLayout.layout([
            commit("L", ["P"], refs: [GitRef(kind: .branch, name: "main")]),
            commit("R", ["P"], refs: [GitRef(kind: .remoteBranch, name: "origin/main")]),
            commit("P", []),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0])
        #expect(rows.map(\.colorIndex) == [0, 0, 0])
    }
}
