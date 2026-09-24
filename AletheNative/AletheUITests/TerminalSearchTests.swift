import XCTest

/// Terminal find bar (P2-4): ⌘F, live count, next/previous, Esc; hit targets at three zoom levels.
@MainActor
final class TerminalSearchTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// A shell with "alpha" printed: the command line and its output hold it four times.
    /// (Test text avoids lowercase "c": XCUITest drops it on the owner's keyboard layout.)
    private func shellWithOutput(_ app: XCUIApplication) -> XCUIElement {
        let project = element(app, "sidebar.project.scratch")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.rightClick()
        app.outlines.menuItems["New Terminal…"].click()
        app.radioButtons["Shell"].click()
        app.buttons["editor.confirm"].click()
        let pane = element(app, "terminal.pane")
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        pane.typeText("printf '%s\\n' alpha beta alpha\n")
        return pane
    }

    private func status(_ app: XCUIApplication) -> String {
        element(app, "find.status").value as? String ?? element(app, "find.status").label
    }

    func testFindCountsNavigatesAndCloses() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        _ = shellWithOutput(app)
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("alpha")
        XCTAssertTrue(eventually { self.status(app).contains("4") }, "count shows \(status(app))")

        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(eventually { self.status(app).contains(" of 4") }, "next selects a match: \(status(app))")
        field.typeText("zzz")
        XCTAssertTrue(eventually { self.status(app) == "No results" })

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !self.element(app, "find.bar").exists }, "Esc closes the bar")
        app.terminate()
    }

    /// HT: the bar's buttons are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testFindBarControlsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
            _ = shellWithOutput(app)
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            app.typeKey("f", modifierFlags: .command)
            let field = app.textFields["find.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F at \(label)")
            field.typeText("alpha")
            XCTAssertTrue(eventually { self.status(app).contains("4") })
            element(app, "find.next").click()
            XCTAssertTrue(eventually { self.status(app).contains(" of 4") }, "next missed at \(label)")
            let first = status(app)
            element(app, "find.previous").click()
            XCTAssertTrue(eventually { self.status(app) != first }, "previous missed at \(label)")
            element(app, "find.close").click()
            XCTAssertTrue(eventually { !self.element(app, "find.bar").exists }, "close missed at \(label)")
            app.terminate()
        }
    }
}
