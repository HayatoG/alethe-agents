import XCTest

/// Home (P3-15): ⇧⌘H switches, the quick launch opens an agent terminal in the workspace.
@MainActor
final class HomeTests: XCTestCase {
    func testShiftCommandHTogglesHome() {
        continueAfterFailure = false
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "grid"])
        let home = app.descendants(matching: .any)["home"]
        XCTAssertFalse(home.exists)
        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.activity"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.time"].exists)
        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(eventually { !home.exists })
        app.terminate()
    }

    func testQuickLaunchOpensATerminal() {
        continueAfterFailure = false
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "grid"])
        app.descendants(matching: .any)["home.button"].firstMatch.click()
        let prompt = app.descendants(matching: .any)["home.quick.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.click()
        paste("hello from home", into: app)
        app.descendants(matching: .any)["home.quick.send"].firstMatch.click()
        XCTAssertTrue(eventually { !app.descendants(matching: .any)["home"].exists })
        app.terminate()
    }
}
