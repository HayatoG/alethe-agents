import XCTest

/// Every upstream agent is offered for a new terminal (P3-1).
@MainActor
final class AgentRosterTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testNewTerminalOffersEveryAgent() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.project.alpha"].waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        for name in ["Claude Code", "Codex", "GitHub Copilot", "Cursor", "Antigravity", "OpenCode", "Mimo",
                     "Freebuff", "Kiro CLI", "Shell"] {
            XCTAssertTrue(agents.radioButtons[name].exists, "\(name) is offered")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
