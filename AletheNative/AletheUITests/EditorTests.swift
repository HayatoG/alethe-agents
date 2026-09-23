import XCTest

@MainActor
final class EditorTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func row(_ app: XCUIApplication, _ kind: String, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.\(kind).\(name)"].firstMatch
    }

    func testNewProjectSheetValidatesAndCreates() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(row(app, "project", "scratch").waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        let folder = app.textFields["editor.project.folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        let confirm = app.buttons["editor.confirm"]
        XCTAssertFalse(confirm.isEnabled, "empty form must not be creatable")

        folder.click()
        folder.typeText("/private/tmp")
        XCTAssertTrue(app.staticTexts["editor.problem"].waitForExistence(timeout: 2), "duplicate folder must be reported")
        XCTAssertFalse(confirm.isEnabled)

        folder.typeKey("a", modifierFlags: .command)
        folder.typeText("/usr/share")
        XCTAssertTrue(eventually { confirm.isEnabled })
        app.buttons["editor.color.green"].click()
        confirm.click()
        XCTAssertTrue(row(app, "project", "share").waitForExistence(timeout: 5))
        app.terminate()
    }

    func testEditGroupRenamesIt() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let clients = row(app, "group", "Clients")
        XCTAssertTrue(clients.waitForExistence(timeout: 5))
        clients.rightClick()
        app.menuItems["Edit Group…"].click()
        let name = app.textFields["editor.group.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Customers")
        app.buttons["editor.confirm"].click()
        XCTAssertTrue(row(app, "group", "Customers").waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, "group", "Clients").exists)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row(app, "group", "Clients").waitForExistence(timeout: 5))
        app.terminate()
    }

    func testNewGroupFromTheMenu() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["editor.group.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.confirm"].isEnabled)
        // The sheet focuses its name field; wait for that before typing so no keystroke is lost.
        XCTAssertTrue(eventually { (name.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        // No lowercase "c": XCUITest's typeText drops it under the Brazilian - Pro layout (real key
        // events reach the field fine).
        name.typeText("Playground")
        XCTAssertEqual(name.value as? String, "Playground")
        app.buttons["editor.confirm"].click()
        XCTAssertTrue(row(app, "group", "Playground").waitForExistence(timeout: 5))
        app.terminate()
    }
}
