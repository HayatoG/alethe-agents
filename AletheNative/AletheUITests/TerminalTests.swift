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
        app.menuItems["New Terminal"].hover()
        app.menuItems["Shell"].click()

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
}
