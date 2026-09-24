import XCTest

/// Page offer (P2-15): a local address printed in a terminal is offered; open it in a pane, or dismiss.
@MainActor
final class PageOfferTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func shell(printing address: String, in app: XCUIApplication) {
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.outlines.menuItems["New Terminal…"].click()
        app.radioButtons["Shell"].click()
        app.buttons["editor.confirm"].click()
        let pane = element(app, "terminal.pane")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        // No lowercase "c" (XCUITest drops it on the owner's layout), hence 127.0.0.1.
        pane.typeText("printf '%s\\n' \(address)\n")
    }

    func testOfferOpensAWebPane() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        shell(printing: "http://127.0.0.1:4321/", in: app)
        XCTAssertTrue(element(app, "pageOffer").waitForExistence(timeout: 10), "the address is offered")
        element(app, "pageOffer.openInPane").click()
        XCTAssertTrue(element(app, "web.pane").waitForExistence(timeout: 5), "a web pane opens beside the terminal")
        XCTAssertTrue(eventually { !self.element(app, "pageOffer").exists }, "the offer goes once taken")
        app.terminate()
    }

    func testDismissedOfferDoesNotReturnForTheSameAddress() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        shell(printing: "http://127.0.0.1:4322/", in: app)
        XCTAssertTrue(element(app, "pageOffer").waitForExistence(timeout: 10))
        element(app, "pageOffer.dismiss").click()
        XCTAssertTrue(eventually { !self.element(app, "pageOffer").exists })
        element(app, "terminal.pane").typeText("printf '%s\\n' http://127.0.0.1:4322/\n")
        XCTAssertFalse(eventually(timeout: 2) { self.element(app, "pageOffer").exists }, "offered once per address")
        app.terminate()
    }
}
