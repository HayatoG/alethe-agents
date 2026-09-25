import XCTest

/// Notifications list in the toolbar (P3-11).
@MainActor
final class NotificationsTests: XCTestCase {
    func testBellShowsTheList() {
        continueAfterFailure = false
        let (app, _) = launchAlethe()
        let bell = app.descendants(matching: .any)["notifications.button"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        bell.click()
        XCTAssertTrue(app.descendants(matching: .any)["notifications.list"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
