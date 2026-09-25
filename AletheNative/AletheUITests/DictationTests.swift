import XCTest

/// Dictation (P3-17): with the microphone denied, ⌥⌘D says so and offers System Settings.
@MainActor
final class DictationTests: XCTestCase {
    func testDeniedMicrophoneExplainsAndDismisses() {
        continueAfterFailure = false
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar", "-AletheDictationDenied", "YES"])
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.project.alpha"].waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: [.command, .option])
        let hud = app.descendants(matching: .any)["dictation.hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["dictation.openSettings"].exists)
        app.descendants(matching: .any)["dictation.dismiss"].firstMatch.click()
        XCTAssertTrue(eventually { !hud.exists })
        app.terminate()
    }
}
