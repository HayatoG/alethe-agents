import XCTest

/// Worker actions on the board (P6-15) over live stub workers (`-AletheUITestSeed orchestratorWorker`:
/// project `workers`, planner tab `tab-lead`, job-01 and job-02 interrupted on their threads, job-03
/// done in a worktree; Codex is a stub script, see `TestSeeds+OrchestratorWorker`).
@MainActor
final class OrchestratorWorkerActionsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchBoard() -> XCUIApplication {
        let app = launchAlethe(arguments: ["-AletheUITestSeed", "orchestratorWorker"]).0
        XCTAssertTrue(element(app, "orchestrator.pane").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "orchestrator.tab.tab-lead").waitForExistence(timeout: 10), "the jobs file is restored")
        return app
    }

    private func select(_ app: XCUIApplication, _ job: String) {
        let row = element(app, "orchestrator.rail.worker.\(job)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(element(app, "orchestrator.worker.\(job).detail").waitForExistence(timeout: 5))
    }

    private func message(_ app: XCUIApplication, _ job: String, _ text: String) {
        let field = element(app, "orchestrator.worker.\(job).message")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        paste(text, into: app)
        let send = element(app, "orchestrator.worker.\(job).send")
        XCTAssertTrue(eventually { send.isEnabled })
        send.click()
    }

    private func report(_ app: XCUIApplication, _ job: String, contains text: String, timeout: TimeInterval = 15) -> Bool {
        let report = element(app, "orchestrator.worker.\(job).report")
        return eventually(timeout: timeout) {
            report.exists && (report.label.contains(text) || (report.value as? String ?? "").contains(text))
        }
    }

    private func mode(_ app: XCUIApplication, _ job: String, _ mode: String) -> XCUIElement {
        element(app, "orchestrator.worker.\(job).mode.\(mode)")
    }

    /// A stub worker blocked on an approval: the ask shows what, where (outside its folder) and why,
    /// nothing is answered until a click, and Approve once lets it carry on. Its diff opens with the
    /// Diff pane's lines.
    func testApprovalIsAnsweredFromTheBoard() {
        let app = launchBoard()
        select(app, "job-01")
        XCTAssertTrue(mode(app, "job-01", "resume").exists, "an interrupted worker is started again by a message")
        message(app, "job-01", "please ask")

        let ask = element(app, "orchestrator.worker.job-01.ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "the worker stops on its question")
        XCTAssertTrue(element(app, "orchestrator.worker.job-01.askCommand").exists)
        XCTAssertTrue(element(app, "orchestrator.worker.job-01.askIn").exists, "an ask outside the worker's folder is called out")
        for decision in ["accept", "acceptForSession", "decline", "abort"] {
            XCTAssertTrue(element(app, "orchestrator.worker.job-01.answer.\(decision)").exists)
        }
        // Nothing answers by itself.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(ask.exists)
        XCTAssertFalse(report(app, "job-01", contains: "answered", timeout: 0.5))

        element(app, "orchestrator.worker.job-01.answer.accept").click()
        XCTAssertTrue(report(app, "job-01", contains: "answered accept"), "the answer reaches the worker")
        XCTAssertTrue(eventually { !ask.exists }, "the ask clears")
        XCTAssertTrue(eventually(timeout: 10) { self.mode(app, "job-01", "steer").exists }, "the worker runs again")

        let toggle = element(app, "orchestrator.worker.job-01.diffToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the worker reported a diff")
        toggle.click()
        let diff = element(app, "orchestrator.worker.job-01.diff")
        XCTAssertTrue(diff.waitForExistence(timeout: 10))
        XCTAssertTrue(eventually { diff.staticTexts["+beta two"].exists }, "the diff is loaded and styled by line")
        toggle.click()
        XCTAssertTrue(eventually { !diff.exists })
        app.terminate()
    }

    /// A running worker is steered (the correction lands on its turn); an idle one takes the message
    /// as its next turn.
    func testSteerVersusSend() {
        let app = launchBoard()
        select(app, "job-02")
        message(app, "job-02", "hold on")
        XCTAssertTrue(eventually(timeout: 15) { self.mode(app, "job-02", "steer").exists }, "running: a message steers")

        message(app, "job-02", "go left")
        XCTAssertTrue(report(app, "job-02", contains: "steered go left"), "the steer lands on the running turn")
        XCTAssertTrue(eventually(timeout: 10) { self.mode(app, "job-02", "next").exists }, "idle: a message is the next turn")

        message(app, "job-02", "more work")
        XCTAssertTrue(report(app, "job-02", contains: "did more work"), "the send runs as a new turn")
        app.terminate()
    }

    /// Cancel asks once while the worker runs (keeping it is a no-op); Release lets a finished worker
    /// go and a message would start it again.
    func testCancelAsksOnceAndReleaseIsReversible() {
        let app = launchBoard()
        select(app, "job-02")
        message(app, "job-02", "hold on")
        XCTAssertTrue(eventually(timeout: 15) { self.mode(app, "job-02", "steer").exists })

        let cancel = element(app, "orchestrator.worker.job-02.cancel")
        cancel.click()
        let keep = element(app, "orchestrator.cancel.keep")
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "cancelling a running worker asks")
        keep.click()
        XCTAssertTrue(mode(app, "job-02", "steer").exists, "keeping it leaves it running")

        cancel.click()
        let confirm = element(app, "orchestrator.cancel.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(eventually(timeout: 10) { !cancel.exists }, "a cancelled worker has nothing left to cancel")
        XCTAssertFalse(element(app, "orchestrator.worker.job-02.message").exists, "a cancelled worker takes no messages")

        select(app, "job-03")
        XCTAssertTrue(mode(app, "job-03", "next").exists)
        XCTAssertTrue(element(app, "orchestrator.worker.job-03.reveal").isEnabled, "the worktree can be shown in Finder")
        let release = element(app, "orchestrator.worker.job-03.release")
        release.click()
        XCTAssertTrue(eventually(timeout: 10) { !release.exists }, "released")
        XCTAssertTrue(mode(app, "job-03", "resume").exists, "a message starts a released worker again")
        app.terminate()
    }

    /// Hit targets at three zoom levels: the message field, send, the diff toggle and Release react
    /// where they are drawn.
    func testActionsReceiveClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let app = launchBoard()
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            select(app, "job-01")
            message(app, "job-01", "hello")
            XCTAssertTrue(report(app, "job-01", contains: "did hello"), "field or send missed at \(label)")

            let toggle = element(app, "orchestrator.worker.job-01.diffToggle")
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            toggle.click()
            XCTAssertTrue(element(app, "orchestrator.worker.job-01.diff").waitForExistence(timeout: 10),
                          "diff toggle missed at \(label)")

            let release = element(app, "orchestrator.worker.job-01.release")
            release.click()
            XCTAssertTrue(eventually(timeout: 10) { !release.exists }, "release missed at \(label)")
            app.terminate()
        }
    }
}
