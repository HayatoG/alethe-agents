import XCTest

/// Conversations sheet ⌘Y (P3-7).
@MainActor
final class ConversationsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testOpensSwitchesAgentAndCloses() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(element(app, "conversations").waitForExistence(timeout: 5))
        let agents = app.radioGroups["conversations.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.radioButtons["Codex"].click()
        XCTAssertTrue(eventually { (agents.radioButtons["Codex"].value as? Int) == 1 })
        XCTAssertFalse(element(app, "conversations.open").isEnabled, "nothing selected yet")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !self.element(app, "conversations").exists })
        app.terminate()
    }
}
