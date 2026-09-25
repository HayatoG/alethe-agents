import XCTest

/// Settings › Multiagent (P6-22) over a seeded `.planning/` project (`-AletheUITestSeed multiagent`:
/// `agentrepo`, a committed three-item roadmap with the first item done, the orchestrator feature on):
/// Run Tick starts the next task in a worktree, Cancel asks once and fails it, and autocommit (off at
/// every launch) commits `.planning/` changes into the history (`multiagentLive` keeps changing it).
@MainActor
final class MultiagentSettingsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchSeeded(_ seed: String = "multiagent", dataRoot: URL = makeTemporaryDataRoot()) -> XCUIApplication {
        let app = launchAlethe(dataRoot: dataRoot, arguments: ["-AletheUITestSeed", seed]).0
        XCTAssertTrue(element(app, "sidebar.project.agentrepo").waitForExistence(timeout: 10))
        return app
    }

    private func openMultiagent(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Multiagent"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the tab shows while the orchestrator feature is on")
        tab.click()
        XCTAssertTrue(element(app, "settings.multiagent").waitForExistence(timeout: 5))
    }

    private func status(_ app: XCUIApplication, _ index: Int) -> String {
        element(app, "multiagent.task.\(index).status").value as? String ?? ""
    }

    func testTickStartsTheNextTaskAndCancelFailsIt() {
        let app = launchSeeded()
        openMultiagent(app)
        // The first project is picked and its queue read from task.md, before any tick.
        XCTAssertTrue(element(app, "multiagent.task.2").waitForExistence(timeout: 10), "three roadmap items")
        XCTAssertEqual(status(app, 0), "Completed")
        XCTAssertEqual(status(app, 1), "Pending")
        XCTAssertEqual(status(app, 2), "Pending")
        XCTAssertTrue(element(app, "multiagent.audit.0").waitForExistence(timeout: 10), "the seed's audit commit")

        element(app, "multiagent.tick").click()
        XCTAssertTrue(eventually(timeout: 20) { self.status(app, 1) == "Running" }, "the next task runs: \(status(app, 1))")
        XCTAssertEqual(status(app, 2), "Pending", "its dependency is not done")
        XCTAssertTrue(element(app, "multiagent.metric.alethe_event_taskstarted").waitForExistence(timeout: 5),
                      "metrics refresh from the bus")
        XCTAssertTrue(element(app, "multiagent.trace.0").exists, "recent events refresh from the bus")

        let cancel = element(app, "multiagent.task.1.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        let confirm = element(app, "multiagent.cancel.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "cancel asks once")
        confirm.click()
        XCTAssertTrue(eventually(timeout: 10) { self.status(app, 1) == "Failed" }, "cancelled: \(status(app, 1))")
        XCTAssertFalse(element(app, "multiagent.task.1.cancel").exists, "only running tasks cancel")
        XCTAssertTrue(element(app, "multiagent.metric.alethe_event_taskfailed").waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
    }

    func testAutocommitRecordsPlanningChangesAndIsOffAtLaunch() {
        let root = makeTemporaryDataRoot()
        let app = launchSeeded("multiagentLive", dataRoot: root)
        openMultiagent(app)
        let toggle = element(app, "multiagent.autocommit")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 0, "off at launch")
        XCTAssertTrue(element(app, "multiagent.audit.0").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "multiagent.audit.1").exists, "only the seed's commit")

        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 1 })
        XCTAssertTrue(element(app, "multiagent.audit.1").waitForExistence(timeout: 30), "a change was committed")
        XCTAssertTrue(element(app, "multiagent.audit.0").label.contains("auto-commit"),
                      "newest first: \(element(app, "multiagent.audit.0").label)")
        app.typeKey("w", modifierFlags: .command)
        app.terminate()

        let relaunched = launchSeeded("multiagentLive", dataRoot: root)
        openMultiagent(relaunched)
        let again = element(relaunched, "multiagent.autocommit")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? Int, 0, "not a preference: off again after a relaunch")
        relaunched.typeKey("w", modifierFlags: .command)
        relaunched.terminate()
    }

    /// Hit targets at three zoom levels: the tab, Run Tick, Cancel and its confirmation, and the
    /// autocommit toggle react where they are drawn.
    func testControlsReceiveClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let app = launchSeeded()
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            openMultiagent(app)
            XCTAssertTrue(element(app, "multiagent.task.1").waitForExistence(timeout: 10))

            element(app, "multiagent.tick").click()
            XCTAssertTrue(eventually(timeout: 20) { self.status(app, 1) == "Running" }, "Run Tick missed at \(label)")
            let cancel = element(app, "multiagent.task.1.cancel")
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.click()
            let confirm = element(app, "multiagent.cancel.confirm")
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Cancel missed at \(label)")
            confirm.click()
            XCTAssertTrue(eventually(timeout: 10) { self.status(app, 1) == "Failed" }, "confirm missed at \(label)")

            let toggle = element(app, "multiagent.autocommit")
            toggle.click()
            XCTAssertTrue(eventually { (toggle.value as? Int) == 1 }, "toggle missed at \(label)")
            toggle.click()
            XCTAssertTrue(eventually { (toggle.value as? Int) == 0 }, "toggle missed at \(label)")
            app.typeKey("w", modifierFlags: .command)
            app.terminate()
        }
    }
}
