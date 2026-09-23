import XCTest

@MainActor
final class PaneHostTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launch() -> XCUIApplication {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        XCTAssertTrue(element(app, "pane.header.four").waitForExistence(timeout: 10))
        return app
    }

    /// Auto layout: two panes side by side, the odd third spanning the row below.
    func testAutoLayoutPlacesPanes() {
        let app = launch()
        let one = element(app, "pane.header.one").frame
        let two = element(app, "pane.header.two").frame
        let three = element(app, "pane.header.three").frame
        XCTAssertEqual(one.minY, two.minY, accuracy: 1)
        XCTAssertLessThan(one.maxX, two.minX)
        XCTAssertGreaterThan(three.minY, one.maxY)
        XCTAssertEqual(three.width, two.maxX - one.minX, accuracy: 2, "the odd pane spans its row")
        XCTAssertGreaterThan(element(app, "pane.header.four").frame.minX, two.maxX, "second project sits to the right")
        app.terminate()
    }

    func testClosingPanesAndContainersIsUndoable() {
        let app = launch()
        let three = element(app, "pane.header.three")
        three.buttons["pane.close"].click()
        XCTAssertTrue(eventually { !three.exists })
        XCTAssertGreaterThan(element(app, "pane.one").frame.height, 600, "remaining panes take the space")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(three.waitForExistence(timeout: 5))

        let web = element(app, "container.web")
        element(app, "container.close.web").click()
        XCTAssertTrue(eventually { !web.exists })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        app.terminate()
    }

    // Split resizing and header drag-to-reorder need real mouse events (XCUITest's synthesized
    // drags never reach AppKit's mouseDragged): see Scripts/smoke/pane-drag.sh.
}
