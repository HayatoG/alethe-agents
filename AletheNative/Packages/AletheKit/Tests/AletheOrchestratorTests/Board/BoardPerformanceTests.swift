import XCTest
@testable import AletheOrchestrator

/// P (P6-14): what the board derives off main on every snapshot for 100 workers in five runs —
/// planner groups, promoted media, the layout — plus the connector steps the canvas draws.
final class BoardPerformanceTests: XCTestCase {
    private func hundredWorkers() -> [JobSnapshot] {
        (1...100).map { index in
            boardJob(
                "job-\(index)",
                run: "run-\((index - 1) / 20 + 1)",
                planner: "tab-lead",
                label: "Batch \((index - 1) / 20 + 1)",
                status: index % 7 == 0 ? .failed : index % 3 == 0 ? .running : .done,
                summary: index % 10 == 0 ? "Screenshot at /tmp/shot-\(index).png\nDone." : "Worker \(index) finished."
            )
        }
    }

    func testLayoutAndConnectorsFor100Workers() {
        let jobs = hundredWorkers()
        let planners = [Planner(id: "tab-lead", label: "lead", agent: "claude")]
        let heights = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, 96.0) })
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let groups = PlannerGroup.group(jobs: jobs, planners: planners)
            let group = groups[0]
            let media = BoardMedia.promotedByJobID(group.jobs)
            let graph = BoardLayout.layout(runs: group.runs, heights: heights, plannerID: group.id, mediaByJobID: media)
            let steps = graph.edges.reduce(0) { $0 + $1.steps.count }
            XCTAssertEqual(graph.workers.count, 100)
            XCTAssertEqual(graph.media.count, 10)
            XCTAssertGreaterThan(steps, graph.edges.count)
        }
    }

    func testTheLayoutOf100WorkersFitsAndStaysInsideItsBounds() {
        let jobs = hundredWorkers()
        let group = PlannerGroup.group(jobs: jobs, planners: [Planner(id: "tab-lead", label: "lead", agent: "claude")])[0]
        let graph = BoardLayout.layout(runs: group.runs, plannerID: group.id)
        XCTAssertEqual(graph.roots.count, 5)
        for node in graph.nodes {
            XCTAssertLessThanOrEqual(node.x + node.width, graph.width)
            XCTAssertLessThanOrEqual(node.y + node.height, graph.height)
        }
        let fitted = BoardLayout.fitView(graph.size, in: BoardSize(width: 1200, height: 800))
        XCTAssertEqual(fitted.scale, BoardLayout.minScale, "100 workers side by side fit only at the smallest scale")
    }
}
