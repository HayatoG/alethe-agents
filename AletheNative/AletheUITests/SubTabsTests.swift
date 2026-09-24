import XCTest

/// Sub-tabs lane (P2-1): switch, add from the lane, close (undoable), lane visibility, and hit
/// targets at three zoom levels.
@MainActor
final class SubTabsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func isSelected(_ item: XCUIElement) -> Bool { item.isSelected }

    func testSwitchAddCloseAndUndo() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "subtabs"])
        let lane = element(app, "subtabs.lane")
        XCTAssertTrue(lane.waitForExistence(timeout: 5), "two tabs always show the lane")
        let one = element(app, "subtab.one"), two = element(app, "subtab.two")
        XCTAssertTrue(eventually { self.isSelected(two) }, "the tab added last is active")

        one.click()
        XCTAssertTrue(eventually { self.isSelected(one) && !self.isSelected(two) })
        XCTAssertTrue(element(app, "pane.header.one").exists, "the header follows the active tab")

        element(app, "subtabs.new").click()
        XCTAssertTrue(app.radioButtons["Shell"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.popUpButtons["Project"].exists, "a sub-tab joins its pane's project")
        XCTAssertEqual(app.textFields["newTerminal.folder"].value as? String, "/private/tmp")
        app.radioButtons["Shell"].click()
        app.buttons["editor.confirm"].click()
        let added = element(app, "subtab.shell")
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { self.isSelected(added) }, "a new sub-tab is shown")

        added.rightClick()
        app.menuItems["Close Sub-tab"].click()
        XCTAssertTrue(eventually { !added.exists })
        XCTAssertTrue(eventually { self.isSelected(one) || self.isSelected(two) })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(added.waitForExistence(timeout: 5), "closing a sub-tab is undoable")
        app.terminate()
    }

    /// One tab hides the lane by default; the header menu shows it and hides it again.
    func testLaneVisibility() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "terminals"])
        let header = element(app, "pane.header.claude")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "subtabs.lane").exists)
        header.rightClick()
        app.menuItems["Show Sub-tabs"].click()
        XCTAssertTrue(element(app, "subtabs.lane").waitForExistence(timeout: 5))
        header.rightClick()
        app.menuItems["Hide Sub-tabs"].click()
        XCTAssertTrue(eventually { !self.element(app, "subtabs.lane").exists })
        app.terminate()
    }

    /// HT: lane items and + are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testLaneControlsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "subtabs"])
            XCTAssertTrue(element(app, "subtabs.lane").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            let one = element(app, "subtab.one"), two = element(app, "subtab.two")
            one.click()
            XCTAssertTrue(eventually { self.isSelected(one) }, "tab click missed at \(label)")
            two.click()
            XCTAssertTrue(eventually { self.isSelected(two) }, "tab click missed at \(label)")
            element(app, "subtabs.new").click()
            XCTAssertTrue(app.buttons["editor.confirm"].waitForExistence(timeout: 5), "+ missed at \(label)")
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }
}
