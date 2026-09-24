import XCTest

/// File › Import from Alethe (Tauri)… (P1-12), against `Fixtures/tauri-projects.json`.
@MainActor
final class TauriImportTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func row(_ app: XCUIApplication, _ kind: String, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.\(kind).\(name)"].firstMatch
    }

    private func openImport(_ app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Import from Alethe (Tauri)…"].click()
    }

    func testPreviewImportAndUndo() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "tauri-projects", ofType: "json"))
        let (app, _) = launchAlethe(arguments: ["-AletheTauriProjectsFile", fixture])
        XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))

        openImport(app)
        let confirm = app.buttons["editor.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Left out (1)"].exists, "the markdown pane is reported")
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()

        // The result stays on screen until Done.
        XCTAssertTrue(app.staticTexts["Imported"].waitForExistence(timeout: 5))
        app.buttons["editor.confirm"].firstMatch.click()

        let group = row(app, "group", "Imported group"), nested = row(app, "group", "Nested group")
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(nested.exists && row(app, "project", "imported-tmp").exists)
        XCTAssertTrue(row(app, "project", "imported-var").exists)
        XCTAssertLessThan(group.frame.minX, nested.frame.minX)

        // Importing again finds nothing new.
        openImport(app)
        XCTAssertTrue(app.descendants(matching: .any)["import.nothingNew"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.confirm"].firstMatch.isEnabled)
        app.buttons["Cancel"].firstMatch.click()

        // One undo removes the whole import.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(eventually { !group.exists && !self.row(app, "project", "imported-var").exists })
        app.terminate()
    }
}
