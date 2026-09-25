import XCTest

/// Find/Jump ⌘K (P2-25).
@MainActor
final class FindJumpTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testJumpToAProjectAndRunACommand() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element(app, "findJump.field").waitForExistence(timeout: 5))
        paste("cli", into: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element(app, "container.client-site").waitForExistence(timeout: 5), "the fuzzy match opened client-site")

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element(app, "findJump.field").waitForExistence(timeout: 5))
        app.typeText("flat work")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(eventually { !self.element(app, "container.collapse.client-site").exists }, "the command ran")
        app.terminate()
    }

    func testArrowsMoveAndEscCloses() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element(app, "findJump.field").waitForExistence(timeout: 5))
        app.typeText("zzzzqq")
        XCTAssertTrue(element(app, "findJump").staticTexts["Nothing found"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !self.element(app, "findJump").exists })
        app.terminate()
    }

    /// HT: result rows are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testRowsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
            XCTAssertTrue(element(app, "sidebar.project.beta").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(element(app, "findJump.field").waitForExistence(timeout: 5))
            app.typeText("beta")
            element(app, "findJump.row.beta").click()
            XCTAssertTrue(element(app, "container.beta").waitForExistence(timeout: 5), "row missed at \(label)")
            app.terminate()
        }
    }
}
