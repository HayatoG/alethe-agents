import XCTest

/// Worktrees sheet from the project context menu (P4-9).
@MainActor
final class WorktreesTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testListsLockedWorktreeAndRefusesRemove() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "worktrees"])
        let project = element(app, "sidebar.project.wtrepo")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.menuItems["Worktrees…"].click()
        XCTAssertTrue(element(app, "worktrees.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "worktrees.row.seed").waitForExistence(timeout: 10), "the seeded worktree is listed")
        XCTAssertTrue(element(app, "worktrees.row.seed.locked").exists, "shown as locked")
        XCTAssertTrue(element(app, "worktrees.row.seed.reason").exists, "with its lock reason")
        XCTAssertFalse(element(app, "worktrees.error").exists)

        element(app, "worktrees.row.seed").click()
        XCTAssertTrue(element(app, "worktrees.unlock").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "worktrees.remove").isEnabled, "a locked worktree cannot be removed")

        element(app, "worktrees.close").click()
        XCTAssertTrue(eventually { !self.element(app, "worktrees.sheet").exists })
        app.terminate()
    }
}
