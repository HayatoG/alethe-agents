import XCTest

/// Web pane (P2-12): load failure shown with reload, address validation, page options, close; hit
/// targets at three zoom levels. No network: the seed points at a closed local port.
@MainActor
final class WebPaneTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testFailureAddressOptionsAndCloseAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "web"])
            XCTAssertTrue(element(app, "web.failure").waitForExistence(timeout: 15), "a refused page says so")
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            XCTAssertFalse(element(app, "web.back").isEnabled)

            let address = app.textFields["web.address"]
            XCTAssertEqual(address.value as? String, "http://127.0.0.1:9/")
            address.click()
            address.typeKey("a", modifierFlags: .command)
            address.typeText("file:///etc/hosts\n")
            XCTAssertEqual(address.value as? String, "file:///etc/hosts", "a refused address is kept for fixing")

            element(app, "web.options").click()
            XCTAssertTrue(app.menuItems["Keep loaded"].waitForExistence(timeout: 5), "options missed at \(label)")
            app.menuItems["Keep loaded"].click()

            element(app, "pane.close").click()
            XCTAssertTrue(eventually { !self.element(app, "web.pane").exists }, "close missed at \(label)")
            app.terminate()
        }
    }
}
