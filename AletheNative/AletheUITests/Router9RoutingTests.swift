import XCTest

/// 9router routing for new terminals (P7-17): the New Terminal sheet offers "Route through 9router"
/// only when routing can apply, and a routed tab launches (and repeats) with 9router's variables. The
/// seeded `claude` is a stub that prints `ROUTED <host:port>` or `UNROUTED`; 9router is a stub install.
@MainActor
final class Router9RoutingTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openSheet(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(element(app, "sidebar.project.routed").waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        let agents = app.radioGroups["newTerminal.agent"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        return agents
    }

    private func findStatus(_ app: XCUIApplication, in pane: XCUIElement, searching text: String) -> String {
        pane.click()
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(text)
        let status = element(app, "find.status")
        var value = ""
        _ = eventually(timeout: 10) {
            value = status.value as? String ?? status.label
            return value.contains("1")
        }
        field.typeKey(.escape, modifierFlags: [])
        return value
    }

    func testToggleAppearsOnlyForSupportedAgentsWhenKeyed() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9Route"])
        let agents = openSheet(app)
        agents.radioButtons["Claude Code"].click()
        let toggle = element(app, "newTerminal.router9")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "offered once the stub install is found")
        XCTAssertEqual(toggle.value as? Int, 0, "off unless Always route new agents is on")
        agents.radioButtons["Shell"].click()
        XCTAssertTrue(eventually { !toggle.exists }, "never offered for a shell")
        app.terminate()
    }

    func testToggleIsHiddenWithoutAnAPIKey() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9RouteKeyless"])
        let agents = openSheet(app)
        agents.radioButtons["Claude Code"].click()
        // Give the install probe time to finish before asserting absence.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(element(app, "newTerminal.router9").exists)
        app.terminate()
    }

    func testRoutedTabLaunchesThroughTheRouterAndRepeatLastKeepsIt() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9Route"])
        let agents = openSheet(app)
        agents.radioButtons["Claude Code"].click()
        let toggle = element(app, "newTerminal.router9")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        XCTAssertTrue(element(app, "newTerminal.router9.start").waitForExistence(timeout: 5),
                      "a Start button while 9router is stopped")
        element(app, "editor.confirm").click()

        let panes = app.descendants(matching: .any).matching(identifier: "terminal.pane")
        XCTAssertTrue(eventually { panes.count == 1 })
        XCTAssertTrue(findStatus(app, in: panes.element(boundBy: 0), searching: "ROUTED 127.0.0.1:20128").contains("1"),
                      "the tab launched with 9router's variables")

        app.typeKey("t", modifierFlags: [.command, .option])
        XCTAssertTrue(eventually { panes.count == 2 }, "⌥⌘T repeats the routed terminal")
        XCTAssertTrue(findStatus(app, in: panes.element(boundBy: 1), searching: "ROUTED 127.0.0.1:20128").contains("1"),
                      "repeat last keeps the routing")
        app.terminate()
    }

    func testUnroutedTabLaunchesWithoutTheVariables() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9Route"])
        let agents = openSheet(app)
        agents.radioButtons["Claude Code"].click()
        XCTAssertTrue(element(app, "newTerminal.router9").waitForExistence(timeout: 10))
        element(app, "editor.confirm").click()
        let panes = app.descendants(matching: .any).matching(identifier: "terminal.pane")
        XCTAssertTrue(eventually { panes.count == 1 })
        XCTAssertTrue(findStatus(app, in: panes.element(boundBy: 0), searching: "UNROUTED").contains("1"))
        app.terminate()
    }
}
