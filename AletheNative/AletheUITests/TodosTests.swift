import XCTest

/// The Todos tab (P4-16) and its Pomodoro (P4-17): add, edit tags, focus, settings, toolbar pill.
@MainActor
final class TodosTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// View › New Todo reveals the tab and focuses the field.
    private func newTodo(_ title: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["New Todo"].click()
        XCTAssertTrue(element(app, "todos.newField").waitForExistence(timeout: 5))
        paste(title, into: app)
        app.typeKey(.return, modifierFlags: [])
    }

    func testAddEditTagsAndFocus() {
        let (app, _) = launchAlethe()
        newTodo("Write the report #docs", in: app)
        let row = app.staticTexts["Write the report"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the todo is listed without its tag words")
        XCTAssertTrue(app.staticTexts["#docs"].firstMatch.exists, "the #word became a tag")

        row.rightClick()
        app.menuItems["Edit Tags"].click()
        XCTAssertTrue(element(app, "todos.tagsField").waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        paste("#review #ui", into: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["#review #ui"].firstMatch.waitForExistence(timeout: 5), "tags were replaced")

        row.rightClick()
        app.menuItems["Focus in Pomodoro"].click()
        XCTAssertTrue(element(app, "pomodoro.focus").waitForExistence(timeout: 5), "the panel shows the focus todo")
        app.terminate()
    }

    func testSettingsSheetOpensAndCloses() {
        let (app, _) = launchAlethe()
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["New Todo"].click()
        let gear = element(app, "todos.settingsButton")
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.click()
        XCTAssertTrue(element(app, "todos.settings.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "todos.settings.folder").exists)
        element(app, "todos.settings.reset").click()
        app.buttons["Reset to Default List"].firstMatch.click()
        element(app, "todos.settings.done").click()
        XCTAssertTrue(eventually { !self.element(app, "todos.settings.sheet").exists })
        XCTAssertTrue(app.staticTexts["Review active workspace"].firstMatch.waitForExistence(timeout: 5), "defaults restored")
        app.terminate()
    }

    func testToolbarPillFollowsARunningSession() {
        let (app, _) = launchAlethe()
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["New Todo"].click()
        XCTAssertFalse(element(app, "pomodoro.toolbarPill").exists, "hidden while idle")
        let start = element(app, "pomodoro.panel").buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        let pill = element(app, "pomodoro.toolbarPill")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "shown while running")
        // Hide the sidebar; the pill brings the Todos tab back.
        app.typeKey("0", modifierFlags: [.command, .option])
        XCTAssertTrue(eventually { !self.element(app, "todos.newField").exists })
        pill.click()
        XCTAssertTrue(element(app, "todos.newField").waitForExistence(timeout: 5))
        element(app, "pomodoro.panel").buttons["Reset"].firstMatch.click()
        XCTAssertTrue(eventually { !self.element(app, "pomodoro.toolbarPill").exists }, "hidden again after reset")
        app.terminate()
    }
}
