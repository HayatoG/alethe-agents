import XCTest

/// Settings › Profiles (P5-9): create, rename and delete. Switching relaunches the app and is left to
/// manual checks.
@MainActor
final class ProfilesTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openProfiles(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Profiles"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(element(app, "settings.profiles.create").waitForExistence(timeout: 5))
    }

    private func create(_ name: String, in app: XCUIApplication) {
        element(app, "settings.profiles.newName").click()
        paste(name, into: app)
        element(app, "settings.profiles.create").click()
    }

    func testCreateRenameAndDelete() {
        let (app, _) = launchAlethe()
        openProfiles(app)
        // The running profile is marked and cannot be deleted.
        XCTAssertTrue(element(app, "settings.profiles.active.Default").exists)
        XCTAssertFalse(element(app, "settings.profiles.delete.Default").isEnabled)

        create("Work", in: app)
        XCTAssertTrue(element(app, "settings.profiles.name.Work").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings.profiles.switch.Work").exists)

        // A taken name is refused, case-insensitively.
        create("work", in: app)
        XCTAssertTrue(element(app, "settings.profiles.error").waitForExistence(timeout: 5))

        element(app, "settings.profiles.rename.Work").click()
        let field = element(app, "settings.profiles.renameField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        paste("Client", into: app)
        element(app, "settings.profiles.renameConfirm").click()
        XCTAssertTrue(element(app, "settings.profiles.name.Client").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "settings.profiles.name.Work").exists)

        // Delete asks once; cancelling keeps the profile.
        element(app, "settings.profiles.delete.Client").click()
        let confirm = element(app, "settings.profiles.deleteConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !confirm.exists })
        XCTAssertTrue(element(app, "settings.profiles.name.Client").exists)

        element(app, "settings.profiles.delete.Client").click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(eventually { !self.element(app, "settings.profiles.name.Client").exists })
        XCTAssertTrue(element(app, "settings.profiles.name.Default").exists)
        app.terminate()
    }

    func testToolbarMenuListsProfiles() {
        let (app, _) = launchAlethe()
        openProfiles(app)
        create("Work", in: app)
        XCTAssertTrue(element(app, "settings.profiles.name.Work").waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)

        let menu = element(app, "profiles.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        XCTAssertTrue(app.menuItems["Work"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Default"].exists)
        app.menuItems["Manage Profiles…"].click()
        XCTAssertTrue(element(app, "settings.profiles.create").waitForExistence(timeout: 5))
        app.terminate()
    }
}
