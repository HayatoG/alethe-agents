import XCTest

/// Settings › Agents (P3-2): turning an agent off removes it from New Terminal.
@MainActor
final class AgentSettingsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testDisabledAgentLeavesNewTerminal() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Agents"].firstMatch.click()
        let kiro = element(app, "settings.agent.kiro")
        XCTAssertTrue(kiro.waitForExistence(timeout: 5))
        kiro.click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        XCTAssertFalse(agents.radioButtons["Kiro CLI"].exists, "Kiro is off")
        XCTAssertTrue(agents.radioButtons["Codex"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    /// HT: the agent toggles and buttons are clicked where drawn at 90 %, 100 % and 120 %.
    func testAgentControlsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe()
            XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            app.typeKey(",", modifierFlags: .command)
            app.toolbars.buttons["Agents"].firstMatch.click()
            let toggle = element(app, "settings.agent.mimo")
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let before = toggle.value as? Int
            toggle.click()
            XCTAssertTrue(eventually { (toggle.value as? Int) != before }, "toggle missed at \(label)")
            app.terminate()
        }
    }
}
