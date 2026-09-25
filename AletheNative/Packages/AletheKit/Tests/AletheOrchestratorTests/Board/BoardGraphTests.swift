import Foundation
import Testing
import AletheIntegrations
@testable import AletheOrchestrator

// Ported from upstream `src/lib/orchestratorGraph.test.ts` (30 cases), plus the media card units.

private typealias L = BoardLayout

private let runTop = L.canvasPadding
private let workerTop = runTop + L.defaultNodeHeight + L.levelGap

private func layout(
    _ jobs: [JobSnapshot],
    heights: [String: Double] = [:],
    planner: String? = nil,
    media: [String: MediaItem] = [:]
) -> BoardGraph {
    L.layout(runs: BoardRun.group(jobs), heights: heights, plannerID: planner, mediaByJobID: media)
}

private func routing(_ verdict: String) -> OrderedJSON {
    ["verdict": .string(verdict), "agent": "codex", "window": "week", "used": 91]
}

@Suite struct LayoutPlannerBoardTests {
    @Test func returnsTheEmptyBoardWhenThePlannerHasNoRuns() {
        #expect(L.layout(runs: []) == .empty)
    }

    @Test func drawsEveryRunOfThePlannerAtOnceOneTreeEachInRunOrder() {
        let board = layout([
            boardJob("job-01", run: "run-a", label: "refactor pty"),
            boardJob("job-02", run: "run-b", label: "migrate CI"),
            boardJob("job-03", run: "run-a"),
        ])
        #expect(board.trees.map(\.id) == ["run-a", "run-b"])
        #expect(board.trees.map(\.label) == ["refactor pty", "migrate CI"])
        #expect(board.roots.map(\.id) == [L.rootNodeID("run-a"), L.rootNodeID("run-b")])
        #expect(board.workers.map(\.id) == ["job-01", "job-03", "job-02"])
    }

    @Test func putsEveryWorkerBelowTheRunItBelongsTo() {
        let board = layout([
            boardJob("job-01", run: "run-a"),
            boardJob("job-02", run: "run-a"),
            boardJob("job-03", run: "run-b"),
        ])
        for root in board.roots {
            for worker in board.workers {
                #expect(worker.y >= root.y + root.height)
            }
        }
        #expect(board.workers.allSatisfy { $0.y == workerTop })
        #expect(board.roots.allSatisfy { $0.y == runTop })
    }

    @Test func spreadsTheWorkersOfARunInOneRowAndCentresTheRunOverIt() {
        let board = layout([
            boardJob("job-01", run: "run-a"),
            boardJob("job-02", run: "run-a"),
            boardJob("job-03", run: "run-a"),
        ])
        #expect(board.workers.map(\.x) == [
            L.canvasPadding,
            L.canvasPadding + L.nodeWidth + L.siblingGap,
            L.canvasPadding + (L.nodeWidth + L.siblingGap) * 2,
        ])
        #expect(board.roots[0].centerX == board.workers[1].centerX)
    }

    @Test func standsTheTreesSideBySideWithAGapAndNeverLetsThemOverlapHorizontally() {
        let board = layout([
            boardJob("job-01", run: "run-a"),
            boardJob("job-02", run: "run-a"),
            boardJob("job-03", run: "run-b"),
            boardJob("job-04", run: "run-c"),
        ])
        #expect(board.trees[0].width == L.nodeWidth * 2 + L.siblingGap)
        for index in 1..<board.trees.count {
            let previous = board.trees[index - 1]
            #expect(board.trees[index].x == previous.x + previous.width + L.treeGap)
        }
    }

    @Test func keepsEveryNodeOfARunInsideThatRunTree() {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-a"), boardJob("job-03", run: "run-b")],
            heights: ["job-01": 130]
        )
        func inside(_ treeIndex: Int, _ ids: [String]) {
            let tree = board.trees[treeIndex]
            for id in ids {
                let node = (board.roots + board.workers).first { $0.id == id }
                #expect(node != nil)
                guard let node else { continue }
                #expect(node.x >= tree.x)
                #expect(node.y >= tree.y)
                #expect(node.x + node.width <= tree.x + tree.width)
                #expect(node.y + node.height <= tree.y + tree.height)
            }
        }
        inside(0, [L.rootNodeID("run-a"), "job-01", "job-02"])
        inside(1, [L.rootNodeID("run-b"), "job-03"])
    }

    @Test func pushesTheWorkerRowDownByTheTallestMeasuredRunCard() {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-b")],
            heights: [L.rootNodeID("run-b"): 120]
        )
        #expect(board.workers.allSatisfy { $0.y == runTop + 120 + L.levelGap })
    }

    @Test func sizesATreeAroundItsOwnTallestWorker() {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-b")],
            heights: ["job-01": 200]
        )
        #expect(board.trees[0].height == workerTop + 200 - runTop)
        #expect(board.trees[1].height == workerTop + L.defaultNodeHeight - runTop)
    }

    @Test func drawsNoPlannerNodeWhenTheJobsCarryNoPlanner() {
        let board = layout([boardJob("job-01", run: "run-a")])
        #expect(board.planner == nil)
        #expect(board.edges.allSatisfy { $0.from == L.rootNodeID("run-a") })
    }

    @Test func rootsTheForestOnThePlannerAboveEveryRunAndCentredOverThem() throws {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-b"), boardJob("job-03", run: "run-b")],
            planner: "pty-1"
        )
        let planner = try #require(board.planner)
        #expect(planner.id == L.plannerNodeID("pty-1"))
        #expect(planner.y == L.canvasPadding)
        for root in board.roots {
            #expect(planner.y + planner.height <= root.y)
            #expect(root.depth == 1)
        }
        #expect(planner.centerX == (board.roots[0].centerX + board.roots[board.roots.count - 1].centerX) / 2)
    }

    @Test func drawsOneEdgePerRunFromThePlannerThenOnePerWorkerFromItsOwnRun() {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-b"), boardJob("job-03", run: "run-a")],
            planner: "pty-1"
        )
        let planner = L.plannerNodeID("pty-1")
        #expect(board.edges.map { [$0.from, $0.to] } == [
            [planner, L.rootNodeID("run-a")],
            [planner, L.rootNodeID("run-b")],
            [L.rootNodeID("run-a"), "job-01"],
            [L.rootNodeID("run-a"), "job-03"],
            [L.rootNodeID("run-b"), "job-02"],
        ])
        #expect(!board.edges.contains { edge in board.workers.contains { $0.id == edge.from } })
    }

    @Test func tagsAWorkerEdgeWithTheLaneOfTheWorkerAndAPlannerEdgeWithTheRunState() {
        let board = layout(
            [
                boardJob("job-01", run: "run-a", status: .done),
                boardJob("job-02", run: "run-a", status: .failed),
                boardJob("job-03", run: "run-b", status: .queued),
            ],
            planner: "pty-1"
        )
        #expect(board.edges.prefix(2).map(\.lane) == [.failed, .queued])
        #expect(board.edges.dropFirst(2).map(\.lane) == [.finished, .failed, .queued])
    }

    @Test func carriesTheWorstStateOfARunOntoItsTree() {
        let board = layout([
            boardJob("job-01", run: "run-a", status: .done),
            boardJob("job-02", run: "run-a", status: .failed),
            boardJob("job-03", run: "run-b", status: .queued),
        ])
        #expect(board.trees.map(\.lane) == [.failed, .queued])
    }

    @Test func leavesEveryEdgeOnTheBottomOfTheParentAndTheTopOfTheChild() {
        let board = layout([boardJob("job-01", run: "run-a")], heights: ["job-01": 200])
        let root = board.roots[0]
        let worker = board.workers[0]
        let edge = board.edges[0]
        #expect(edge.path.hasPrefix("M\(jsNumber(root.centerX)) \(jsNumber(root.y + root.height))"))
        #expect(edge.path.hasSuffix("V\(jsNumber(worker.y))"))
    }

    @Test func sizesTheBoardAroundEveryTree() {
        let board = layout([boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-b")])
        #expect(board.width == L.canvasPadding * 2 + L.nodeWidth * 2 + L.treeGap)
        #expect(board.height == workerTop + L.defaultNodeHeight + L.canvasPadding)
    }
}

@Suite struct ConnectorPathTests {
    private func path(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
        L.connectorPath(from: BoardPoint(x: x1, y: y1), to: BoardPoint(x: x2, y: y2))
    }

    @Test func dropsStraightDownWhenBothAnchorsShareAColumn() {
        #expect(path(142, 270, 142, 296) == "M142 270 V296")
    }

    @Test func elbowsRightThroughTheMidpoint() {
        #expect(path(100, 270, 200, 370) == "M100 270 V312 Q100 320 108 320 H192 Q200 320 200 328 V370")
    }

    @Test func elbowsLeftThroughTheMidpoint() {
        #expect(path(200, 270, 100, 370) == "M200 270 V312 Q200 320 192 320 H108 Q100 320 100 328 V370")
    }

    @Test func shrinksTheCornerRadiusOnNarrowHops() {
        #expect(path(0, 0, 6, 100) == "M0 0 V47 Q0 50 3 50 H3 Q6 50 6 53 V100")
    }
}

@Suite struct ViewMathsTests {
    @Test func clampsTheScaleToTheSupportedRange() {
        #expect(L.clampScale(10) == L.maxScale)
        #expect(L.clampScale(0.01) == L.minScale)
        #expect(L.clampScale(0.8) == 0.8)
    }

    @Test func fitsTheGraphInsideTheViewportAndCentresIt() {
        #expect(L.fitView(BoardSize(width: 800, height: 400), in: BoardSize(width: 400, height: 400))
            == ViewTransform(scale: 0.5, x: 0, y: 100))
    }

    @Test func neverZoomsPastOneToOneWhenFittingASmallGraph() {
        #expect(L.fitView(BoardSize(width: 200, height: 100), in: BoardSize(width: 800, height: 600)).scale == 1)
    }

    @Test func fallsBackToTheIdentityTransformWithoutAGraphOrAViewport() {
        #expect(L.fitView(BoardGraph.empty.size, in: BoardSize(width: 800, height: 600)) == .identity)
        #expect(L.fitView(BoardSize(width: 10, height: 10), in: BoardSize(width: 0, height: 0)) == .identity)
    }

    @Test func keepsThePointUnderTheCursorFixedWhileZooming() {
        let view = L.zoom(ViewTransform(scale: 0.5, x: 0, y: 0), by: 2, at: BoardPoint(x: 100, y: 50))
        #expect(view == ViewTransform(scale: 1, x: -100, y: -50))
    }

    @Test func returnsTheSameTransformWhenTheScaleIsAlreadyClamped() {
        let view = ViewTransform(scale: L.maxScale, x: 12, y: 8)
        #expect(L.zoom(view, by: 2, at: BoardPoint(x: 0, y: 0)) == view)
    }

    @Test func centresANodeInTheViewportWithoutChangingTheScale() {
        let node = GraphNode(id: "a", kind: .worker, depth: 1, index: 0, x: 100, y: 100, width: 200, height: 40)
        #expect(L.focusView(node.box, view: .identity, in: BoardSize(width: 600, height: 400))
            == ViewTransform(scale: 1, x: 100, y: 80))
    }

    @Test func centresAWholeRunTreeTheSameWay() {
        let tree = BoardBox(x: 40, y: 40, width: 252, height: 208)
        #expect(L.focusView(tree, view: .identity, in: BoardSize(width: 600, height: 400))
            == ViewTransform(scale: 1, x: 134, y: 56))
    }
}

@Suite struct RoutingTraceTests {
    @Test func labelsAWorkerEdgeOnlyWhenOneSideWasRunningOut() {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-a", routing: routing("ignored"))],
            planner: "pty-1"
        )
        let workerEdges = board.edges.filter { $0.to.hasPrefix("job-") }
        #expect(workerEdges.map { $0.note?.verdict } == [nil, "ignored"])
    }

    @Test func neverLabelsAPlannerEdgeWhichCarriesNoSingleChoice() {
        let board = layout([boardJob("job-01", run: "run-a", routing: routing("chosen"))], planner: "pty-1")
        let plannerEdges = board.edges.filter { $0.from == L.plannerNodeID("pty-1") }
        #expect(!plannerEdges.isEmpty)
        #expect(plannerEdges.allSatisfy { $0.note == nil })
    }

    @Test func putsTheLabelOnTheConnectorSoItCanBeDrawn() throws {
        let board = layout([boardJob("job-01", run: "run-a", routing: routing("chosen"))], planner: "pty-1")
        let note = try #require(board.edges.first { $0.to == "job-01" }?.note)
        #expect(note.used == 91)
        #expect(note.x.isFinite)
        #expect(note.y.isFinite)
    }
}

@Suite struct MediaCardLayoutTests {
    private let image = MediaItem(kind: .imageLocal, value: "/repo/out/chart.png")

    @Test func putsAPromotedImageInACardDirectlyBelowItsWorker() throws {
        let board = layout(
            [boardJob("job-01", run: "run-a"), boardJob("job-02", run: "run-a")],
            media: ["job-02": image]
        )
        let card = try #require(board.media.first)
        let worker = board.workers[1]
        #expect(board.media.count == 1)
        #expect(card.id == L.mediaNodeID("job-02"))
        #expect(card.kind == .media)
        #expect(card.depth == worker.depth + 1)
        #expect(card.x == worker.x)
        #expect(card.y == worker.y + worker.height + L.levelGap)
    }

    @Test func linksTheCardToItsWorkerInTheWorkersLaneAndGrowsTheTree() {
        let board = layout([boardJob("job-01", run: "run-a", status: .failed)], media: ["job-01": image])
        let edge = board.edges.last
        #expect(edge?.from == "job-01")
        #expect(edge?.to == L.mediaNodeID("job-01"))
        #expect(edge?.lane == .failed)
        #expect(edge?.note == nil)
        #expect(board.trees[0].height == workerTop + L.defaultNodeHeight * 2 + L.levelGap - runTop)
        #expect(board.height == workerTop + L.defaultNodeHeight * 2 + L.levelGap + L.canvasPadding)
    }

    @Test func connectorStepsMirrorTheSVGPath() {
        let steps = L.connectorSteps(from: BoardPoint(x: 100, y: 270), to: BoardPoint(x: 200, y: 370))
        #expect(steps.count == 6)
        #expect(steps.map(\.svg).joined(separator: " ")
            == "M100 270 V312 Q100 320 108 320 H192 Q200 320 200 328 V370")
    }
}
