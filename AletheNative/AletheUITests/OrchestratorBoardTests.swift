import XCTest

/// The board canvas (P6-14) over a seeded jobs file (`-AletheUITestSeed orchestratorBoard`: project
/// `board` with a disabled Claude Code planner tab `tab-lead` and a board pane; run-01 holds done,
/// failed and interrupted workers, run-02 one finished worker, run-03 comes from outside a terminal).
@MainActor
final class OrchestratorBoardTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchBoard(_ seed: String = "orchestratorBoard") -> XCUIApplication {
        let app = launchAlethe(arguments: ["-AletheUITestSeed", seed]).0
        XCTAssertTrue(element(app, "orchestrator.pane").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "orchestrator.tab.tab-lead").waitForExistence(timeout: 10), "the jobs file is restored")
        return app
    }

    private func zoomValue(_ app: XCUIApplication) -> String {
        element(app, "orchestrator.zoomValue").label
    }

    func testTabsRailAndWorkerDetail() {
        let app = launchBoard()
        let lead = element(app, "orchestrator.tab.tab-lead")
        XCTAssertTrue(lead.isSelected, "the declared planner opens first")
        XCTAssertTrue(element(app, "orchestrator.tab.none").exists, "work from outside a terminal gets its own tab")
        XCTAssertTrue(element(app, "orchestrator.node.planner").exists)

        // Runs: the one needing the person first and open; the finished one folded.
        let first = element(app, "orchestrator.rail.run.run-01")
        let second = element(app, "orchestrator.rail.run.run-02")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "attention first")
        XCTAssertTrue(element(app, "orchestrator.rail.worker.job-02").exists, "an unsettled run opens")
        XCTAssertFalse(element(app, "orchestrator.rail.worker.job-04").exists, "a finished run is folded")
        second.click()
        XCTAssertTrue(element(app, "orchestrator.rail.worker.job-04").waitForExistence(timeout: 5))

        // Workers inside a run by lane (upstream `RUN_LANE_ORDER`): interrupted, failed, finished.
        let interrupted = element(app, "orchestrator.rail.worker.job-03").frame.minY
        let failed = element(app, "orchestrator.rail.worker.job-02").frame.minY
        let done = element(app, "orchestrator.rail.worker.job-01").frame.minY
        XCTAssertLessThan(interrupted, failed)
        XCTAssertLessThan(failed, done)

        // Selecting a worker opens its detail with its report and plan.
        element(app, "orchestrator.rail.worker.job-01").click()
        let detail = element(app, "orchestrator.worker.job-01.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the rail selects the worker")
        let report = element(app, "orchestrator.worker.job-01.report")
        XCTAssertTrue(report.exists)
        XCTAssertTrue(report.label.contains("All tests pass") || (report.value as? String ?? "").contains("All tests pass"))
        XCTAssertTrue(element(app, "orchestrator.rail.worker.job-01").isSelected)

        // Clicking the card again closes the detail.
        element(app, "orchestrator.worker.job-01.card").click()
        XCTAssertTrue(eventually { !detail.exists }, "the card toggles its detail")

        // The other tab: its run, no planner node.
        element(app, "orchestrator.tab.none").click()
        XCTAssertTrue(element(app, "orchestrator.rail.run.run-03").waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { !self.element(app, "orchestrator.node.planner").exists })
        XCTAssertTrue(element(app, "orchestrator.attention.tab-lead").exists, "the planner needing the person is listed")
        element(app, "orchestrator.attention.tab-lead").click()
        XCTAssertTrue(eventually { lead.isSelected })
        app.terminate()
    }

    func testFitRestoresTheViewAfterZoomAndFocus() {
        let app = launchBoard()
        XCTAssertTrue(element(app, "orchestrator.zoomValue").waitForExistence(timeout: 5))
        let fitted = zoomValue(app)
        element(app, "orchestrator.zoomIn").click()
        element(app, "orchestrator.zoomIn").click()
        XCTAssertTrue(eventually { self.zoomValue(app) != fitted }, "zoom in changes the scale")
        element(app, "orchestrator.zoomFit").click()
        XCTAssertTrue(eventually { self.zoomValue(app) == fitted }, "fit returns to the fitted scale: \(zoomValue(app))")

        element(app, "orchestrator.rail.worker.job-02").click()
        let card = element(app, "orchestrator.node.worker.job-02")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "orchestrator.focus").isEnabled, "focus works on the selected worker")
        let board = element(app, "orchestrator.board").frame
        XCTAssertTrue(eventually { abs(card.frame.midX - board.midX) < board.width / 4 }, "the rail brings the worker into view")
        app.terminate()
    }

    /// Hit targets at three zoom levels: planner tabs, rail rows, worker cards and zoom controls
    /// react where they are drawn.
    func testControlsReceiveClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let app = launchBoard()
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            let none = element(app, "orchestrator.tab.none")
            none.click()
            XCTAssertTrue(eventually { none.isSelected }, "planner tab missed at \(label)")
            element(app, "orchestrator.tab.tab-lead").click()
            XCTAssertTrue(element(app, "orchestrator.rail.worker.job-02").waitForExistence(timeout: 5))

            element(app, "orchestrator.rail.worker.job-02").click()
            XCTAssertTrue(element(app, "orchestrator.worker.job-02.detail").waitForExistence(timeout: 5),
                          "rail row missed at \(label)")
            element(app, "orchestrator.worker.job-02.card").click()
            XCTAssertTrue(eventually { !self.element(app, "orchestrator.worker.job-02.detail").exists },
                          "worker card missed at \(label)")

            let before = zoomValue(app)
            element(app, "orchestrator.zoomOut").click()
            XCTAssertTrue(eventually { self.zoomValue(app) != before }, "zoom out missed at \(label)")
            element(app, "orchestrator.zoomFit").click()
            XCTAssertTrue(eventually { self.zoomValue(app) == before }, "fit missed at \(label)")
            app.terminate()
        }
    }

    /// P: a board of 100 workers (five runs) laid out and redrawn through zoom and fit.
    func testLayoutAndRedrawWith100Workers() {
        let app = launchBoard("orchestratorLarge")
        XCTAssertTrue(element(app, "orchestrator.rail.run.run-05").waitForExistence(timeout: 10))
        let fitted = zoomValue(app)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            element(app, "orchestrator.zoomIn").click()
            XCTAssertTrue(eventually { self.zoomValue(app) != fitted })
            element(app, "orchestrator.zoomFit").click()
            XCTAssertTrue(eventually { self.zoomValue(app) == fitted })
        }
        app.terminate()
    }
}
