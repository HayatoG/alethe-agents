import XCTest

/// Applying a worker's worktree (P6-16) over `-AletheUITestSeed orchestratorApply`: job `job-01` is
/// done, and its worktree on `alethe/agent-job-01` holds an uncommitted `feature.txt` that merges
/// cleanly into `main`.
@MainActor
final class OrchestratorApplyTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testCleanApplyAsksOnceAndMergesIntoTheBranch() {
        let app = launchAlethe(arguments: ["-AletheUITestSeed", "orchestratorApply"]).0
        XCTAssertTrue(element(app, "orchestrator.pane").waitForExistence(timeout: 10))
        let row = element(app, "orchestrator.rail.worker.job-01")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the jobs file is restored")
        row.click()
        XCTAssertTrue(element(app, "orchestrator.worker.job-01.detail").waitForExistence(timeout: 5))

        // The first click only shows what will change and asks.
        let action = element(app, "orchestrator.apply.job-01.action")
        XCTAssertTrue(action.waitForExistence(timeout: 5), "a done worker with a worktree offers Apply")
        action.click()
        let confirmation = element(app, "orchestrator.apply.job-01.confirmation")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        let files = element(app, "orchestrator.apply.job-01.files")
        XCTAssertTrue(files.exists)
        XCTAssertTrue(files.label.contains("feature.txt"), "the pending file is listed: \(files.label)")

        // Cancel closes the confirmation without applying anything.
        element(app, "orchestrator.apply.job-01.cancel").click()
        XCTAssertTrue(eventually { !confirmation.exists })
        XCTAssertTrue(action.waitForExistence(timeout: 5))

        action.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        element(app, "orchestrator.apply.job-01.confirm").click()
        let applied = element(app, "orchestrator.apply.job-01.applied")
        XCTAssertTrue(applied.waitForExistence(timeout: 30), "a clean apply finishes on the board")
        XCTAssertTrue(applied.label.contains("main"), "the target branch is named: \(applied.label)")
        XCTAssertFalse(element(app, "orchestrator.apply.job-01.action").exists, "an applied job is not offered again")
        XCTAssertFalse(element(app, "merge.center").exists, "a clean apply does not open the Merge Center")

        // Reselecting the worker still shows it applied for the session.
        element(app, "orchestrator.worker.job-01.card").click()
        XCTAssertTrue(eventually { !self.element(app, "orchestrator.worker.job-01.detail").exists })
        row.click()
        XCTAssertTrue(element(app, "orchestrator.apply.job-01.applied").waitForExistence(timeout: 5))
        app.terminate()
    }
}
