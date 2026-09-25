import XCTest

/// Project menu › Export Settings… / Import Settings… (P5-6): the items are there and open the
/// system save/open panels. The file format and the change list are covered by the package tests.
@MainActor
final class ProjectSettingsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchSeeded() -> (XCUIApplication, XCUIElement) {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = app.descendants(matching: .any)["sidebar.project.scratch"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        return (app, project)
    }

    private func panelIsShown(_ app: XCUIApplication) -> Bool {
        eventually { app.sheets.count + app.dialogs.count > 0 || app.windows.count > 1 }
    }

    func testExportOpensASavePanel() {
        let (app, project) = launchSeeded()
        project.rightClick()
        app.menuItems["Export Settings…"].click()
        XCTAssertTrue(panelIsShown(app))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testImportOpensAnOpenPanel() {
        let (app, project) = launchSeeded()
        project.rightClick()
        XCTAssertTrue(app.menuItems["Import Settings…"].waitForExistence(timeout: 5))
        app.menuItems["Import Settings…"].click()
        XCTAssertTrue(panelIsShown(app))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
