import XCTest

/// Named project grids (P2-20): create one, switch between grids, move a pane into it.
@MainActor
final class ProjectGridsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testCreateSwitchAndMove() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        XCTAssertTrue(element(app, "pane.header.one").waitForExistence(timeout: 5))

        let layout = element(app, "container.layout.api")
        layout.click()
        layout.menuItems["New Grid…"].click()
        let field = app.textFields["projectGrid.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Review")
        app.dialogs.firstMatch.buttons["Create"].click()
        XCTAssertTrue(element(app, "container.grids.api").waitForExistence(timeout: 5), "the grid menu appears")
        XCTAssertTrue(eventually { !self.element(app, "pane.header.one").exists }, "the new grid starts empty")

        let grids = element(app, "container.grids.api")
        grids.click()
        grids.menuItems["Main"].click()
        XCTAssertTrue(element(app, "pane.header.one").waitForExistence(timeout: 5), "back to the main grid")

        element(app, "pane.header.two").rightClick()
        app.menuItems["Move to Grid"].hover()
        app.menuItems["Review"].click()
        XCTAssertTrue(eventually { !self.element(app, "pane.header.two").exists }, "two left the main grid")
        grids.click()
        grids.menuItems["Review"].click()
        XCTAssertTrue(element(app, "pane.header.two").waitForExistence(timeout: 5), "two is in Review")
        app.terminate()
    }
}
