import XCTest

/// Git Control (P4-5), opened through the built-in plugin's contribution on a seeded repository:
/// grouped changes, stage, and branch creation with name validation.
@MainActor
final class GitControlTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Launches on the `git` seed and opens Git Control from the project's context menu.
    private func openGitControl() -> XCUIApplication {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "git"])
        let project = element(app, "sidebar.project.repo")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.rightClick()
        app.menuItems["Git Control…"].click()
        XCTAssertTrue(element(app, "git.control").waitForExistence(timeout: 5))
        return app
    }

    func testShowsChangesAndStagesAFile() {
        let app = openGitControl()
        XCTAssertTrue(element(app, "git.file.notes.txt").waitForExistence(timeout: 10), "the modified file is listed")
        XCTAssertTrue(element(app, "git.file.draft.txt").exists, "the untracked file is listed")
        XCTAssertFalse(element(app, "git.commit").isEnabled, "nothing staged yet")
        app.buttons["Stage All"].click()
        element(app, "git.message").click()
        paste("seeded change", into: app)
        XCTAssertTrue(eventually(timeout: 10) { self.element(app, "git.commit").isEnabled }, "staged with a message")
        element(app, "git.close").click()
        XCTAssertTrue(eventually { !self.element(app, "git.control").exists })
        app.terminate()
    }

    func testCreatesABranchWithValidation() {
        let app = openGitControl()
        let branch = element(app, "git.branch")
        XCTAssertTrue(eventually(timeout: 10) { branch.isEnabled })
        branch.click()
        app.menuItems["New Branch…"].click()
        let name = element(app, "git.newBranch.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "git.newBranch.create").isEnabled, "an empty name is refused")
        name.click()
        paste("bad name", into: app)
        XCTAssertTrue(element(app, "git.newBranch.issue").waitForExistence(timeout: 5), "spaces are refused")
        XCTAssertFalse(element(app, "git.newBranch.create").isEnabled)
        app.typeKey("a", modifierFlags: .command)
        paste("main", into: app)
        XCTAssertTrue(eventually { !self.element(app, "git.newBranch.create").isEnabled }, "an existing branch is refused")
        app.typeKey("a", modifierFlags: .command)
        paste("feature/ui-test", into: app)
        XCTAssertTrue(eventually { self.element(app, "git.newBranch.create").isEnabled })
        element(app, "git.newBranch.create").click()
        XCTAssertTrue(eventually(timeout: 10) { branch.label.contains("feature/ui-test") }, "switched to the new branch")
        app.terminate()
    }
}
