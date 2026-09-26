import XCTest

/// Phase 7 app slots (P7-6): Settings › Integrations and › Remote open, and the `remote`, `router9`
/// and `sync` toolbar items are offered.
@MainActor
final class PeripheralSlotsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testIntegrationsAndRemoteSettingsTabsOpen() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        for title in ["Integrations", "Remote"] {
            let tab = app.toolbars.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(title) is a Settings tab")
            tab.click()
            // The Settings window takes the title of the tab shown.
            XCTAssertTrue(app.windows[title].waitForExistence(timeout: 5), "\(title) opened")
        }
        app.terminate()
    }

    func testPeripheralToolbarItemsAreOffered() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        let customize = app.menuBars.menuItems["Customize Toolbar…"]
        XCTAssertTrue(customize.exists)
        XCTAssertTrue(customize.isEnabled)

        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Toolbar"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        // Settings › Toolbar lists exactly the items the toolbar (and its customization palette) offers.
        for item in ["remote", "router9", "sync"] {
            let toggle = element(app, "settings.toolbar.\(item)")
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(item) is offered")
            let before = toggle.value as? Int
            toggle.click()
            XCTAssertTrue(eventually { (toggle.value as? Int) != before }, "\(item) toggles")
        }
        app.typeKey("w", modifierFlags: .command)

        customize.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "the customization palette opens")
        app.sheets.firstMatch.buttons["Done"].firstMatch.click()
        app.terminate()
    }
}
