import XCTest

/// Model picker in New Terminal (P3-5).
@MainActor
final class ModelPickerTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testClaudeOffersItsAliasesAndShellHasNoModel() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.radioButtons["Claude Code"].click()
        let choices = element(app, "newTerminal.model.choices")
        XCTAssertTrue(choices.waitForExistence(timeout: 5))
        choices.click()
        choices.menuItems["opus"].click()
        XCTAssertEqual(element(app, "newTerminal.model").value as? String, "opus")
        agents.radioButtons["Shell"].click()
        XCTAssertTrue(eventually { !self.element(app, "newTerminal.model").exists }, "a shell has no model")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
