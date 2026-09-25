import XCTest

/// Empty workspace launcher (P2-22).
@MainActor
final class WorkspaceLauncherTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testFirstRunOffersAgentsAndFolder() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(element(app, "launcher.openFolder").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "launcher.agent.shell").exists)
        element(app, "launcher.agent.shell").click()
        XCTAssertTrue(eventually { self.element(app, "launcher.agent.shell").isSelected })
        element(app, "launcher.useForm").click()
        XCTAssertTrue(app.buttons["editor.confirm"].waitForExistence(timeout: 5), "the New Project form opens")
        app.terminate()
    }

    func testQuickActionsOpenProjectAndSheets() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "launcher.open").waitForExistence(timeout: 5))
        element(app, "launcher.newTerminal").click()
        XCTAssertTrue(app.buttons["editor.confirm"].waitForExistence(timeout: 5), "New Terminal opens")
        app.typeKey(.escape, modifierFlags: [])
        element(app, "launcher.open").click()
        XCTAssertTrue(eventually { !self.element(app, "launcher.open").exists }, "a project opens")
        app.terminate()
    }

    /// HT: launcher rows are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testLauncherReceivesClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
            XCTAssertTrue(element(app, "launcher.newProject").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            element(app, "launcher.newProject").click()
            XCTAssertTrue(app.buttons["editor.confirm"].waitForExistence(timeout: 5), "row missed at \(label)")
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }
}
