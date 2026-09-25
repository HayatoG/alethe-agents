import XCTest

/// Disable and enable a terminal (P2-23).
@MainActor
final class DisableTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testDisableAndEnableATerminal() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        XCTAssertTrue(element(app, "pane.header.one").waitForExistence(timeout: 5))
        element(app, "pane.header.one").rightClick()
        app.menuItems["Disable Terminal"].click()
        XCTAssertTrue(element(app, "pane.disabled").waitForExistence(timeout: 5), "the pane shows it is disabled")
        element(app, "pane.enable").click()
        XCTAssertTrue(eventually { !self.element(app, "pane.disabled").exists }, "enabled again")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane.disabled").waitForExistence(timeout: 5), "⌘Z disables it again")
        app.terminate()
    }
}
