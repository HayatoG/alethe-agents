import XCTest

/// Image pane (P2-10): fit / actual size and close, with hit targets at three zoom levels.
@MainActor
final class MediaPaneTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testImageFitsActualSizeAndClosesAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "media"])
            XCTAssertTrue(element(app, "image.fitted").waitForExistence(timeout: 5), "fitted by default")
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            element(app, "image.size").click()
            XCTAssertTrue(element(app, "image.actual").waitForExistence(timeout: 5), "actual size missed at \(label)")
            element(app, "image.size").click()
            XCTAssertTrue(element(app, "image.fitted").waitForExistence(timeout: 5), "fit missed at \(label)")
            element(app, "pane.close").click()
            XCTAssertTrue(eventually { !self.element(app, "image.pane").exists }, "close missed at \(label)")
            app.terminate()
        }
    }
}
