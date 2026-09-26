import XCTest

/// 9router settings, install sheet and toolbar pill (P7-16) against a stub install: "node" is
/// `/bin/sh` running a sleeping script, so nothing real is installed or started. Every control is
/// clicked where it is drawn and its effect checked (HT).
@MainActor
final class Router9Tests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openIntegrations(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Integrations"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
    }

    private func stateLabel(_ app: XCUIApplication) -> String {
        let state = element(app, "router9.state")
        return (state.value as? String) ?? state.label
    }

    func testSettingsStartStopAndAPIKeyAgainstAStubInstall() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9"])
        openIntegrations(app)

        XCTAssertTrue(element(app, "router9.installInfo").waitForExistence(timeout: 10), "the stub install is found")
        XCTAssertTrue(eventually(timeout: 10) { self.stateLabel(app).contains("Ready") })

        // The key is saved to the Keychain (in memory for UI tests) and never shown again.
        let field = element(app, "router9.apiKey.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        paste("9r_uitest_secret", into: app)
        element(app, "router9.apiKey.save").click()
        XCTAssertTrue(element(app, "router9.apiKey.saved").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                              "9r_uitest", "9r_uitest")).firstMatch.exists)

        let toggle = element(app, "router9.toggleRunning")
        toggle.click()
        XCTAssertTrue(eventually(timeout: 10) { self.stateLabel(app).contains("127.0.0.1") }, "started")
        XCTAssertTrue(element(app, "router9.dashboard").isEnabled)
        toggle.click()
        XCTAssertTrue(eventually(timeout: 10) { self.stateLabel(app).contains("Ready") }, "stopped")

        // Turning it off hides the connection rows.
        element(app, "router9.enabled").click()
        XCTAssertTrue(eventually { !self.element(app, "router9.autoStart").exists })
        XCTAssertTrue(eventually { self.stateLabel(app).contains("Off") })
        app.terminate()
    }

    func testToolbarPillStartsAndStops() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "router9"])
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        let pill = element(app, "toolbar.router9")
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "shown while enabled and installed")
        XCTAssertEqual(pill.value as? String, "off")
        pill.click()
        XCTAssertTrue(eventually(timeout: 10) { (pill.value as? String) == "on" }, "started from the pill")
        pill.click()
        XCTAssertTrue(eventually(timeout: 10) { (pill.value as? String) == "off" }, "stopped from the pill")
        app.terminate()
    }

    func testInstallSheetShowsTheExactCommandAndAsksFirst() {
        let (app, dataRoot) = launchAlethe(arguments: ["-AletheUITestSeed", "router9Fresh", "-AletheInstallDryRun", "YES"])
        openIntegrations(app)

        let install = element(app, "router9.install")
        XCTAssertTrue(install.waitForExistence(timeout: 10), "offered when nothing is installed")
        install.click()
        let command = element(app, "router9.install.command")
        XCTAssertTrue(command.waitForExistence(timeout: 10))
        let text = (command.value as? String) ?? command.label
        XCTAssertTrue(text.hasPrefix("npm install --prefix '"), text)
        XCTAssertTrue(text.contains(dataRoot.path), "the private prefix lives in the profile")
        XCTAssertTrue(text.hasSuffix("9router@0.5.59"), text)
        // Nothing ran yet: closing leaves no log behind.
        XCTAssertFalse(element(app, "router9.install.log").exists)
        element(app, "router9.install.close").click()
        XCTAssertTrue(eventually { !command.exists }, "the sheet closes without running")
        app.terminate()
    }
}
