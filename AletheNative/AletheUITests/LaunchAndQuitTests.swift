import XCTest

/// Start clean and quit confirmation (P2-26).
@MainActor
final class LaunchAndQuitTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testQuitAsksWhileTerminalsRunAndCanBeCancelled() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "terminals", "-AletheConfirmQuit", "YES"])
        XCTAssertTrue(element(app, "pane.header.claude").waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 1),
                      "quitting asks first")
        let alert = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        alert.buttons["Cancel"].click()
        XCTAssertEqual(app.state, .runningForeground, "Cancel keeps Alethe open")
        app.terminate()
    }

    func testStartCleanOpensNothing() {
        let (app, root) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        XCTAssertTrue(element(app, "container.api").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        // Settings reopens on the last tab it showed.
        app.toolbars.buttons["General"].firstMatch.click()
        let toggle = element(app, "settings.startClean")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertTrue(relaunched.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5),
                      "nothing is open")
        XCTAssertTrue(relaunched.descendants(matching: .any)["workspaceTabs"].exists, "the tabs stay to pick from")
        relaunched.terminate()
    }
}
