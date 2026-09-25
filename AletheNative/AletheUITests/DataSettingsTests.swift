import XCTest

/// Settings › General › Data (P5-10): every destructive action asks once, and cancelling changes
/// nothing. Confirming relaunches the app, which UI tests never do.
@MainActor
final class DataSettingsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openGeneral(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "sidebar.project.scratch").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["General"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        let reset = element(app, "settings.data.reset")
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        // The Data section sits below the general toggles.
        for _ in 0..<5 where !reset.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300) }
    }

    /// Asks, is cancelled, and leaves the seeded project in place.
    private func cancelDialog(_ app: XCUIApplication, button: String, confirm: String) {
        element(app, button).click()
        let confirmButton = element(app, confirm)
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "\(button) did not ask")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !confirmButton.exists }, "\(button) dialog stayed")
    }

    func testDestructiveActionsAskAndCancelChangesNothing() {
        let backup = "/private/tmp/alethe-uitest-backup-\(UUID().uuidString).zip"
        let (app, root) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar", "-AletheUITestBackupFile", backup])
        openGeneral(app)

        // Export writes without asking; the status names the file.
        element(app, "settings.data.export").click()
        XCTAssertTrue(element(app, "settings.data.status").waitForExistence(timeout: 15), "export reported nothing")

        // Import of that file shows what it holds and asks.
        cancelDialog(app, button: "settings.data.import", confirm: "settings.data.importConfirm")
        cancelDialog(app, button: "settings.data.reset", confirm: "settings.data.resetConfirm")
        cancelDialog(app, button: "settings.data.erase", confirm: "settings.data.eraseConfirm")
        XCTAssertFalse(element(app, "settings.data.error").exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "sidebar.project.scratch").exists)
        app.terminate()

        // After a relaunch the workspace is as it was: nothing was scheduled.
        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertTrue(element(relaunched, "sidebar.project.scratch").waitForExistence(timeout: 5))
        relaunched.terminate()
    }

    func testCorruptBackupIsRefused() {
        // A folder is not an archive: staging fails before anything changes.
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar", "-AletheUITestBackupFile", "/private/tmp"])
        openGeneral(app)
        element(app, "settings.data.import").click()
        XCTAssertTrue(element(app, "settings.data.error").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "settings.data.importConfirm").exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "sidebar.project.scratch").exists)
        app.terminate()
    }
}
