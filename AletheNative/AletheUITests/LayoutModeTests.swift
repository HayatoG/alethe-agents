import XCTest

/// Spotlight and Sidebar layouts (P2-18): the layout picker in the container header.
@MainActor
final class LayoutModeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func choose(_ mode: String, in app: XCUIApplication) {
        let picker = element(app, "container.layout.api")
        picker.click()
        picker.menuItems[mode].click()
    }

    func testSpotlightAndSidebar() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        // The panes, not their headers (headers all have the same height).
        let one = element(app, "pane.one"), two = element(app, "pane.two")
        XCTAssertTrue(one.waitForExistence(timeout: 5))

        choose("Spotlight", in: app)
        XCTAssertTrue(eventually { one.frame.maxX < two.frame.minX && one.frame.height > two.frame.height * 1.5 },
                      "the first pane is large on the left")
        choose("Sidebar", in: app)
        XCTAssertTrue(eventually { one.frame.minX > two.frame.maxX }, "the first pane is large on the right")
        choose("Auto", in: app)
        XCTAssertTrue(eventually { abs(one.frame.width - two.frame.width) < 2 }, "rows of two again")
        app.terminate()
    }

    /// HT: the layout picker opens where it is drawn at 90 %, 100 % and 120 %.
    func testLayoutPickerReceivesClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
            XCTAssertTrue(element(app, "container.layout.api").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            let picker = element(app, "container.layout.api")
            picker.click()
            XCTAssertTrue(picker.menuItems["Spotlight"].waitForExistence(timeout: 5), "picker missed at \(label)")
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }
}
