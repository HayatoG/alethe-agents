import XCTest

/// Settings › Integrations › Discord (P7-13): the Rich Presence toggle and its persistence. Test
/// launches use a silent client, so nothing reaches a running Discord.
@MainActor
final class DiscordPresenceTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openToggle(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Integrations"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        let toggle = element(app, "settings.discord.presence")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    func testToggleIsOffByDefaultAndPersists() {
        let (app, root) = launchAlethe()
        let toggle = openToggle(app)
        XCTAssertEqual(toggle.value as? Int, 0, "off until the user turns it on")
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 1 })
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertEqual(openToggle(relaunched).value as? Int, 1, "the choice survives a relaunch")
        relaunched.terminate()
    }

    func testSeededOnTurnsOff() {
        let (app, root) = launchAlethe(arguments: ["-AletheUITestSeed", "discordPresence"])
        let toggle = openToggle(app)
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 0 })
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertEqual(openToggle(relaunched).value as? Int, 0)
        relaunched.terminate()
    }
}
