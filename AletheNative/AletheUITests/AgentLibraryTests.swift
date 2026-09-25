import XCTest

/// Project menu › Agent Library… (P5-16) on a project seeded with one agent Alethe did not write.
@MainActor
final class AgentLibraryTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openLibrary(_ app: XCUIApplication) {
        let project = element(app, "sidebar.project.agentsproj")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.menuItems["Agent Library…"].click()
        XCTAssertTrue(element(app, "agentLibrary.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "agentLibrary.list").waitForExistence(timeout: 5))
    }

    func testInstallUndoAndRemove() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "agentLibrary"])
        openLibrary(app)
        XCTAssertTrue(element(app, "agentLibrary.row.orchestrator").exists, "library templates are listed")
        XCTAssertFalse(element(app, "agentLibrary.status.qa-reviewer").exists)

        element(app, "agentLibrary.install.qa-reviewer").click()
        XCTAssertTrue(element(app, "agentLibrary.status.qa-reviewer").waitForExistence(timeout: 5), "shown as installed")
        XCTAssertTrue(element(app, "agentLibrary.remove.qa-reviewer").exists)

        element(app, "agentLibrary.undo").click()
        XCTAssertTrue(element(app, "agentLibrary.install.qa-reviewer").waitForExistence(timeout: 5), "undo removes the fresh install")

        element(app, "agentLibrary.install.qa-reviewer").click()
        XCTAssertTrue(element(app, "agentLibrary.remove.qa-reviewer").waitForExistence(timeout: 5))
        element(app, "agentLibrary.remove.qa-reviewer").click()
        XCTAssertTrue(element(app, "agentLibrary.install.qa-reviewer").waitForExistence(timeout: 5),
                      "Alethe's own file is removed without asking")
        XCTAssertFalse(element(app, "agentLibrary.error").exists)

        element(app, "agentLibrary.close").click()
        XCTAssertTrue(eventually { !self.element(app, "agentLibrary.sheet").exists })
        app.terminate()
    }

    func testEconomyToggleAndForeignAgentAsks() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "agentLibrary"])
        openLibrary(app)

        let economy = element(app, "agentLibrary.economy")
        XCTAssertTrue(economy.waitForExistence(timeout: 5))
        XCTAssertEqual(economy.value as? Int, 0)
        economy.click()
        XCTAssertTrue(element(app, "agentLibrary.status.haiku-summarizer").waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { (economy.value as? Int) == 1 })
        economy.click()
        XCTAssertTrue(eventually { !self.element(app, "agentLibrary.status.haiku-summarizer").exists })

        // The seeded agent was not written by Alethe: removing it asks once.
        let remove = element(app, "agentLibrary.remove.mine")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(app.buttons["Remove"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "agentLibrary.row.mine").exists, "cancelled: the file stays")
        app.terminate()
    }
}
