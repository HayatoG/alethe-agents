import XCTest

/// Diff pane (P2-11): unified and side-by-side, staged toggle; hit targets at three zoom levels.
@MainActor
final class DiffPaneTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testLayoutsAndStagedAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "diff"])
            XCTAssertTrue(element(app, "diff.unified").waitForExistence(timeout: 10), "the change is shown")
            XCTAssertTrue(app.staticTexts["+gamma"].exists)
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            element(app, "diff.layout").click()
            XCTAssertTrue(element(app, "diff.split").waitForExistence(timeout: 5), "side by side missed at \(label)")
            element(app, "diff.staged").click()
            XCTAssertTrue(element(app, "diff.empty").waitForExistence(timeout: 10), "nothing staged, at \(label)")
            element(app, "diff.staged").click()
            XCTAssertTrue(element(app, "diff.split").waitForExistence(timeout: 10), "back to the working tree at \(label)")
            element(app, "pane.close").click()
            XCTAssertTrue(eventually { !self.element(app, "diff.pane").exists }, "close missed at \(label)")
            app.terminate()
        }
    }
}
