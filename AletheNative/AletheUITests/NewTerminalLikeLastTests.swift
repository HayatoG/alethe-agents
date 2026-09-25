import XCTest

/// New Terminal Like Last ⌥⌘T (P3-4).
@MainActor
final class NewTerminalLikeLastTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testRepeatsTheLastChoiceWithoutTheSheet() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.scratch").waitForExistence(timeout: 5))
        element(app, "sidebar.project.scratch").click()
        app.typeKey("t", modifierFlags: .command)
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.radioButtons["Shell"].click()
        element(app, "editor.confirm").click()
        let shells = app.descendants(matching: .any).matching(identifier: "pane.header.shell")
        XCTAssertTrue(eventually { shells.count == 1 })
        app.typeKey("t", modifierFlags: [.command, .option])
        XCTAssertTrue(eventually { shells.count == 2 }, "⌥⌘T adds another shell without the sheet")
        XCTAssertFalse(agents.exists)
        app.terminate()
    }
}
