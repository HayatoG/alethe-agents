import XCTest

/// Setup steps on Home (P3-16): shown until done, hidden on request, back from the Help menu.
@MainActor
final class SetupWalkthroughTests: XCTestCase {
    func testHideAndShowAgain() {
        continueAfterFailure = false
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        app.typeKey("h", modifierFlags: [.command, .shift])
        let setup = app.descendants(matching: .any)["setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["setup.project"].firstMatch.value as? String, "Done")
        app.descendants(matching: .any)["setup.hide"].firstMatch.click()
        XCTAssertTrue(eventually { !setup.exists })
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Show Setup Steps"].click()
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        app.terminate()
    }
}
