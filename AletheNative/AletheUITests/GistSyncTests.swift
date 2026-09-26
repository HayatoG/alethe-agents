import XCTest

/// GitHub Sync (P7-15) over the in-process stub GitHub of `-AletheUITestSeed gistSync` (token
/// `ghp_uitest`); never the real API. Confirming a pull relaunches the app, which UI tests never do.
@MainActor
final class GistSyncTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func launchSeeded() -> XCUIApplication {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "gistSync"])
        XCTAssertTrue(element(app, "sidebar.project.synced").waitForExistence(timeout: 5))
        return app
    }

    private func openSheet(_ app: XCUIApplication) {
        let button = element(app, "gistSync.button")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the toolbar Sync item is shown by default")
        button.click()
        XCTAssertTrue(element(app, "gistSync.token").waitForExistence(timeout: 5))
    }

    private func connect(_ app: XCUIApplication, token: String) {
        element(app, "gistSync.token").click()
        paste(token, into: app)
        element(app, "gistSync.connect").click()
    }

    func testConnectPushAndPullAsksBeforeReplacing() {
        let app = launchSeeded()
        openSheet(app)

        // A refused token is reported and nothing is stored.
        connect(app, token: "ghp_wrong")
        XCTAssertTrue(element(app, "gistSync.error").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "gistSync.token").exists)

        // A valid one connects; the token is not shown anywhere afterwards.
        connect(app, token: "ghp_uitest")
        let connectedAs = element(app, "gistSync.connectedAs")
        XCTAssertTrue(connectedAs.waitForExistence(timeout: 10))
        XCTAssertTrue(text(connectedAs).contains("octo-uitest"))
        XCTAssertFalse(element(app, "gistSync.token").exists)
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'ghp_uitest'")).count, 0)

        // Pull before any push: nothing to download.
        element(app, "gistSync.pull").click()
        XCTAssertTrue(element(app, "gistSync.error").waitForExistence(timeout: 10))

        // Push creates the gist.
        element(app, "gistSync.push").click()
        XCTAssertTrue(element(app, "gistSync.notice").waitForExistence(timeout: 10))
        XCTAssertFalse(text(element(app, "gistSync.lastPush")).contains("never"))
        XCTAssertTrue(element(app, "gistSync.openGist").exists)

        // Pull asks first; cancelling changes nothing.
        element(app, "gistSync.pull").click()
        let confirm = element(app, "gistSync.pullConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "a pull asks before replacing data")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !confirm.exists })
        XCTAssertTrue(text(element(app, "gistSync.lastPull")).contains("never"))
        XCTAssertFalse(element(app, "gistSync.error").exists)

        // Disconnect forgets the token.
        element(app, "gistSync.disconnect").click()
        XCTAssertTrue(element(app, "gistSync.token").waitForExistence(timeout: 10))
        element(app, "gistSync.done").click()
        XCTAssertTrue(eventually { !self.element(app, "gistSync.sheet").exists })
        XCTAssertTrue(element(app, "sidebar.project.synced").exists)
        app.terminate()
    }

    func testSettingsDataOpensTheSheet() {
        let app = launchSeeded()
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["General"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        let open = element(app, "settings.data.gistSync")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        for _ in 0..<5 where !open.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300) }
        open.click()
        XCTAssertTrue(element(app, "gistSync.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "gistSync.token").exists)
        app.terminate()
    }

    /// HT: at 120 % zoom the sheet's controls take clicks where they are drawn.
    func testSheetControlsReceiveClicksWhenZoomed() {
        let app = launchSeeded()
        for _ in 0..<2 {
            app.menuBars.menuBarItems["View"].click()
            app.menuItems["Zoom In"].click()
        }
        openSheet(app)
        connect(app, token: "ghp_uitest")
        XCTAssertTrue(element(app, "gistSync.connectedAs").waitForExistence(timeout: 10), "token field and Connect")

        element(app, "gistSync.push").click()
        XCTAssertTrue(element(app, "gistSync.notice").waitForExistence(timeout: 10), "Upload")

        element(app, "gistSync.pull").click()
        XCTAssertTrue(element(app, "gistSync.pullConfirm").waitForExistence(timeout: 10), "Download")
        app.typeKey(.escape, modifierFlags: [])

        element(app, "gistSync.disconnect").click()
        XCTAssertTrue(element(app, "gistSync.token").waitForExistence(timeout: 10), "Disconnect")

        element(app, "gistSync.done").click()
        XCTAssertTrue(eventually { !self.element(app, "gistSync.sheet").exists }, "Done")
        app.terminate()
    }
}
