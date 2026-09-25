import XCTest

/// Open in VS Code, Reveal in Finder and Open in Browser in the project and terminal menus (P5-7).
@MainActor
final class OpenInTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testProjectMenuHasTheOpenInItems() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        XCTAssertTrue(app.menuItems["Open in VS Code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Show in Finder"].exists)
        XCTAssertTrue(app.menuItems["Open in Browser"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    /// `/private/tmp` has no clone URL and no remote: a clear message instead of a silent no-op.
    func testOpenInBrowserExplainsAMissingWebAddress() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.menuItems["Open in Browser"].click()
        XCTAssertTrue(app.staticTexts["This project has no web address."].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        app.terminate()
    }

    func testTerminalMenuHasTheOpenInItems() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "terminals"])
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        app.outlineRows.containing(.any, identifier: "sidebar.project.scratch").disclosureTriangles.firstMatch.click()
        let tab = element(app, "sidebar.tab.claude")
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.rightClick()
        XCTAssertTrue(app.menuItems["Open in VS Code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Show in Finder"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
