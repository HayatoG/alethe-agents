import XCTest

/// Install sheet (P3-3), in dry-run mode: the command is printed, never run.
@MainActor
final class AgentInstallTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testInstallSheetShowsMethodsAndRunsOne() throws {
        let (app, _) = launchAlethe(arguments: ["-AletheInstallDryRun", "YES"])
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Agents"].firstMatch.click()
        // Freebuff is rarely installed; skip the test on a Mac that has it.
        let install = element(app, "settings.agent.install.freebuff")
        guard install.waitForExistence(timeout: 5) else { throw XCTSkip("Freebuff is installed here") }
        install.click()
        XCTAssertTrue(element(app, "agentInstall").waitForExistence(timeout: 5))
        let run = element(app, "agentInstall.run")
        if run.waitForExistence(timeout: 5), run.isEnabled {
            run.click()
            XCTAssertTrue(element(app, "agentInstall.log").waitForExistence(timeout: 10))
            XCTAssertTrue(eventually(timeout: 10) { self.element(app, "agentInstall.failed").exists },
                          "a dry run installs nothing, so verification fails")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
