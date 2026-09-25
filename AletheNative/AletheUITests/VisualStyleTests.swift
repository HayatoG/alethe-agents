import XCTest

/// Clean style and reduced motion (P2-27).
@MainActor
final class VisualStyleTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testCleanStyleCompactsTheSidebarAndPersists() {
        let (app, root) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let row = element(app, "sidebar.project.scratch")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let normalHeight = row.frame.height
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["Clean"].firstMatch.click()
        XCTAssertTrue(eventually { row.frame.height < normalHeight }, "the sidebar gets compact")
        app.checkBoxes["settings.reduceMotion"].firstMatch.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertTrue(relaunched.descendants(matching: .any)["sidebar.project.scratch"].waitForExistence(timeout: 5))
        relaunched.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(relaunched.radioButtons["Clean"].firstMatch.value as? Int, 1, "Clean survives a relaunch")
        XCTAssertEqual(relaunched.checkBoxes["settings.reduceMotion"].firstMatch.value as? Int, 1)
        relaunched.terminate()
    }

    /// HT: the style controls are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testStyleControlsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe()
            XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            app.typeKey(",", modifierFlags: .command)
            let clean = app.radioButtons["Clean"].firstMatch
            XCTAssertTrue(clean.waitForExistence(timeout: 5))
            clean.click()
            XCTAssertTrue(eventually { (clean.value as? Int) == 1 }, "style missed at \(label)")
            let motion = app.checkBoxes["settings.reduceMotion"].firstMatch
            motion.click()
            XCTAssertTrue(eventually { (motion.value as? Int) == 1 }, "motion toggle missed at \(label)")
            app.terminate()
        }
    }
}
