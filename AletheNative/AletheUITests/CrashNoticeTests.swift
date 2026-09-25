import XCTest

/// After-crash notice and Help › Diagnostics… (P5-11), with an unclean session marker seeded by
/// `-AletheUITestCrashMarker`.
@MainActor
final class CrashNoticeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testNoticeAfterUncleanExitThenDiagnostics() throws {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestCrashMarker", "YES"])
        let notice = app.descendants(matching: .any)["crashNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the notice follows an unclean exit")
        XCTAssertTrue(app.staticTexts["Alethe quit unexpectedly"].exists)
        XCTAssertTrue(app.staticTexts["Nothing is sent automatically. A report is shared only if you choose to."].exists)

        app.buttons["crash.dismiss"].firstMatch.click()
        XCTAssertTrue(eventually { !notice.exists })

        // The unclean exit is recorded as a warning and listed in Diagnostics.
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Diagnostics…"].click()
        let sheet = app.descendants(matching: .any)["diagnostics"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.list"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Export JSON…"].firstMatch.isEnabled)
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(eventually { !sheet.exists })
        app.terminate()
    }

    func testNoNoticeWithoutSeededMarker() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["crashNotice"].firstMatch.exists)
        app.terminate()
    }
}
