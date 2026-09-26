import XCTest

/// Remote control's app service (P7-12): with the `remoteMessage` seed, remote control is on (bound
/// to 127.0.0.1) and a stub device sends a message to the shared terminal.
@MainActor
final class RemoteControlTests: XCTestCase {
    func testADeviceMessageShowsInTheNotificationList() {
        continueAfterFailure = false
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "remoteMessage"])
        let bell = app.descendants(matching: .any)["notifications.button"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10))

        bell.click()

        let list = app.descendants(matching: .any)["notifications.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let entry = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Test Phone sent a message",
                                  "Test Phone sent a message"))
            .firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
