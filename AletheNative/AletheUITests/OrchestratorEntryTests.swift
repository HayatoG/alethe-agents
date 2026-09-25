import XCTest

/// Orchestrator pane entry points (P6-13): New Terminal › Orchestration opens a planner with the
/// board beside it and turns the feature on; Add Content and the project menu offer the board only
/// while the feature is on.
@MainActor
final class OrchestratorEntryTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testOrchestrationModeOpensAPlannerAndABoard() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.click()
        app.typeKey("t", modifierFlags: .command)
        let mode = app.radioGroups["newTerminal.mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "the mode is offered with the feature off")
        mode.radioButtons["Orchestration"].click()
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.radioButtons["Claude Code"].waitForExistence(timeout: 5))
        XCTAssertFalse(agents.radioButtons["Shell"].exists, "only planner agents")
        agents.radioButtons["Claude Code"].click()
        element(app, "editor.confirm").click()

        XCTAssertTrue(element(app, "pane.header.claude").waitForExistence(timeout: 10), "the planner opens")
        XCTAssertTrue(element(app, "orchestrator.pane").waitForExistence(timeout: 5), "the board opens beside it")
        XCTAssertTrue(element(app, "orchestrator.empty").exists, "the feature is on: the board, not the notice")
        app.terminate()
    }

    func testEntryPointsFollowTheFeature() {
        let (off, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let scratch = element(off, "sidebar.project.scratch")
        XCTAssertTrue(scratch.waitForExistence(timeout: 5))
        scratch.click()
        off.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(off, "addContent.diff").waitForExistence(timeout: 5))
        XCTAssertFalse(element(off, "addContent.orchestrator").exists, "Add Content hides the board")
        off.typeKey(.escape, modifierFlags: [])
        scratch.rightClick()
        XCTAssertTrue(off.menuItems["Edit Project…"].waitForExistence(timeout: 5))
        XCTAssertFalse(off.menuItems["Add Orchestration"].exists, "the project menu hides it")
        off.typeKey(.escape, modifierFlags: [])
        off.terminate()

        let (on, _) = launchAlethe(arguments: ["-AletheUITestSeed", "orchestrator"])
        let project = element(on, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        let add = on.menuItems["Add Orchestration"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        XCTAssertTrue(element(on, "orchestrator.pane").waitForExistence(timeout: 5), "the project menu adds a board")
        on.typeKey("a", modifierFlags: [.command, .shift])
        let option = element(on, "addContent.orchestrator")
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Add Content offers the board")
        option.click()
        let boards = on.descendants(matching: .any).matching(identifier: "orchestrator.pane")
        XCTAssertTrue(eventually { boards.count == 2 }, "Add Content adds another board")
        on.terminate()
    }
}
