import XCTest

/// Settings › Appearance (P1-11): theme, app icon (P5-12), UI zoom and language.
@MainActor
final class AppearanceTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func openAppearance(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Appearance"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.theme"].firstMatch.waitForExistence(timeout: 5))
    }

    private func tile(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["settings.theme.\(id)"].firstMatch
    }

    func testThemePickerAppliesAndPersists() {
        let (app, root) = launchAlethe()
        openAppearance(app)
        XCTAssertEqual(tile(app, "elite-indigo").value as? String, "1", "default theme not selected")
        tile(app, "nord").click()
        XCTAssertTrue(eventually { self.tile(app, "nord").value as? String == "1" })
        XCTAssertEqual(tile(app, "elite-indigo").value as? String, "0")
        // The screen, not `app.windows.firstMatch`: that can be an invisible helper window with no image.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "appearance-nord"
        shot.lifetime = .keepAlways
        add(shot)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        openAppearance(relaunched)
        XCTAssertEqual(tile(relaunched, "nord").value as? String, "1", "theme not restored after relaunch")
        relaunched.terminate()
    }

    /// Hit targets at three zoom levels: every Appearance control is clicked where it is drawn and
    /// its effect checked.
    func testAppearanceControlsReceiveClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let (app, _) = launchAlethe()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            openAppearance(app)

            let value = app.staticTexts["settings.zoom.value"].firstMatch
            // A static text reports its string as the value; the label stays empty.
            var shown: String { value.value as? String ?? "" }
            XCTAssertTrue(eventually { shown == label }, "zoom shows \(shown)")

            app.buttons["settings.zoom.in"].firstMatch.click()
            let raised = "\(Int(label.dropLast())! + 10)%"
            XCTAssertTrue(eventually { shown == raised }, "zoom in missed at \(label): \(shown)")
            app.buttons["settings.zoom.out"].firstMatch.click()
            XCTAssertTrue(eventually { shown == label }, "zoom out missed at \(label): \(shown)")
            app.buttons["settings.zoom.in"].firstMatch.click()
            XCTAssertTrue(eventually { shown == raised })
            app.buttons["settings.zoom.reset"].firstMatch.click()
            XCTAssertTrue(eventually { shown == "100%" }, "reset missed at \(label)")

            tile(app, "dracula").click()
            XCTAssertTrue(eventually { self.tile(app, "dracula").value as? String == "1" }, "theme tile missed at \(label)")

            let language = app.popUpButtons["settings.language"].firstMatch
            language.click()
            app.menuItems["Português (Brasil)"].click()
            let note = app.descendants(matching: .any)["settings.language.restartNote"].firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 5), "language picker missed at \(label)")
            // Back to System: the choice is stored in the app's real defaults domain.
            language.click()
            app.menuItems["System"].click()
            XCTAssertTrue(eventually { !note.exists }, "restart note stayed at \(label)")
            app.terminate()
        }
    }
    /// App icon picker (P5-12) at three zoom levels: every tile selects where it is drawn, and the
    /// choice survives a relaunch.
    func testAppIconPickerReceivesClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let (app, root) = launchAlethe()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            openAppearance(app)
            func icon(_ id: String) -> XCUIElement { app.descendants(matching: .any)["settings.appIcon.\(id)"].firstMatch }
            XCTAssertTrue(icon("elite-indigo").waitForExistence(timeout: 5))
            XCTAssertEqual(icon("elite-indigo").value as? String, "1", "default icon not selected at \(label)")
            for id in ["elite-original", "elite-pure-black", "elite-blush"] {
                icon(id).click()
                XCTAssertTrue(eventually { icon(id).value as? String == "1" }, "\(id) missed at \(label)")
            }
            XCTAssertEqual(icon("elite-indigo").value as? String, "0")
            app.terminate()

            let (relaunched, _) = launchAlethe(dataRoot: root)
            openAppearance(relaunched)
            let restored = relaunched.descendants(matching: .any)["settings.appIcon.elite-blush"].firstMatch
            XCTAssertEqual(restored.value as? String, "1", "icon not restored after relaunch at \(label)")
            relaunched.terminate()
        }
    }
}
