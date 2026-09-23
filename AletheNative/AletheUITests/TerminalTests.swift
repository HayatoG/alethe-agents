import XCTest

@MainActor
final class TerminalTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// New shell from the sidebar → `exit` shows the ended overlay → Restart → Close Terminal (+ undo).
    func testShellLifecycle() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.outlines.menuItems["New Terminal…"].click()
        app.radioButtons["Shell"].click()
        app.buttons["editor.confirm"].click()

        let pane = element(app, "terminal.pane")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        let overlay = element(app, "terminal.overlay")
        XCTAssertFalse(overlay.exists)

        pane.click()
        pane.typeText("exit\n")
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), "an ended process must say so")
        element(app, "terminal.restart").click()
        XCTAssertTrue(eventually { !overlay.exists }, "restart must replace the ended process")

        app.outlineRows.containing(.any, identifier: "sidebar.project.scratch").disclosureTriangles.firstMatch.click()
        let tab = element(app, "sidebar.tab.shell")
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.rightClick()
        app.menuItems["Close Terminal"].click()
        XCTAssertTrue(element(app, "workspace.project.empty").waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// ⌘T: folder validation, creation, and the last agent remembered for next time.
    func testNewTerminalSheet() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.scratch").waitForExistence(timeout: 5))
        element(app, "sidebar.project.scratch").click()
        app.typeKey("t", modifierFlags: .command)
        let folder = app.textFields["newTerminal.folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertEqual(folder.value as? String, "/private/tmp", "starts in the project folder")
        app.radioButtons["Shell"].click()
        XCTAssertFalse(app.textViews["newTerminal.prompt"].exists, "a shell takes no prompt")

        folder.click()
        folder.typeKey("a", modifierFlags: .command)
        folder.typeText("/nowhere/at/all")
        XCTAssertTrue(app.staticTexts["editor.problem"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["editor.confirm"].isEnabled)
        folder.typeKey("a", modifierFlags: .command)
        folder.typeText("/usr")
        XCTAssertTrue(eventually { app.buttons["editor.confirm"].isEnabled })
        app.buttons["editor.confirm"].click()
        XCTAssertTrue(element(app, "terminal.pane").waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.radioButtons["Shell"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.radioButtons["Shell"].value as? Int, 1, "the last agent is preselected")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
