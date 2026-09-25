import XCTest

/// GSD Sync UI (P5-24) over a seeded `.planning/` folder (`-AletheUITestSeed gsdSync`: a repository
/// with a busy child session and a 1-of-3 roadmap, a project holding a disabled OpenCode tab, the
/// feature on): the right sidebar tab, the sidebar planning row, the activity sheet and the model
/// chain in Settings › Features.
@MainActor
final class GSDSyncTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchSeeded(dataRoot: URL = makeTemporaryDataRoot()) -> XCUIApplication {
        launchAlethe(dataRoot: dataRoot, arguments: ["-AletheUITestSeed", "gsdSync", "-main.rightSidebarVisible", "YES"]).0
    }

    /// Selects the GSD Sync tab of the right sidebar.
    private func showGSDTab(_ app: XCUIApplication) -> XCUIElement {
        let tabs = element(app, "rightSidebar.tabs")
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        let tab = tabs.radioButtons["GSD Sync"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the project runs OpenCode and the feature is on")
        tab.click()
        return tab
    }

    private func openFeatures(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Features"].firstMatch.click()
        let more = element(app, "settings.features.showMore")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        XCTAssertTrue(element(app, "settings.feature.gsdSync").waitForExistence(timeout: 5))
    }

    func testTabListsTheSeededSessionWithItsPlanningStatus() {
        let app = launchSeeded()
        _ = showGSDTab(app)
        let row = element(app, "gsdSync.row.gsdrepo")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the poll found the child session")
        XCTAssertTrue(app.staticTexts["1/3 tasks"].exists, "roadmap progress from task.md")
        XCTAssertTrue(app.staticTexts["Syncing"].exists, "busy from .gsd-child-busy")

        let planning = element(app, "sidebar.planning.gsdrepo")
        XCTAssertTrue(planning.waitForExistence(timeout: 5), "planning status under the project in the sidebar")

        row.click()
        let sheet = element(app, "gsdActivity.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["gsdrepo"].exists, "titled with the checkout")
        // No real child session exists: the export ends in a message, never a hang.
        XCTAssertTrue(element(app, "gsdActivity.error").waitForExistence(timeout: 40))
        element(app, "gsdActivity.done").click()
        XCTAssertTrue(eventually { !self.element(app, "gsdActivity.sheet").exists })

        planning.click()
        XCTAssertTrue(element(app, "gsdActivity.sheet").waitForExistence(timeout: 5), "the sidebar row opens it too")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    func testTurningGSDSyncOffHidesItsSurfaces() {
        let app = launchSeeded()
        _ = showGSDTab(app)
        XCTAssertTrue(element(app, "sidebar.planning.gsdrepo").waitForExistence(timeout: 10))

        openFeatures(app)
        let toggle = element(app, "settings.feature.gsdSync")
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 0 })
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(eventually(timeout: 10) { !self.element(app, "rightSidebar.tabs").radioButtons["GSD Sync"].exists })
        XCTAssertTrue(eventually(timeout: 10) { !self.element(app, "sidebar.planning.gsdrepo").exists })
        app.terminate()
    }

    func testModelChainPersists() {
        let root = makeTemporaryDataRoot()
        let app = launchSeeded(dataRoot: root)
        XCTAssertTrue(element(app, "rightSidebar.tabs").waitForExistence(timeout: 10))
        openFeatures(app)
        XCTAssertTrue(element(app, "settings.gsdSync.empty").waitForExistence(timeout: 5))
        element(app, "settings.gsdSync.add").click()
        let field = element(app, "settings.gsdSync.model.0")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        paste("anthropic/claude-sonnet-4", into: app)
        app.typeKey(.return, modifierFlags: [])
        element(app, "settings.gsdSync.add").click()
        XCTAssertTrue(element(app, "settings.gsdSync.model.1").waitForExistence(timeout: 5))
        element(app, "settings.gsdSync.remove.1").click()
        XCTAssertTrue(eventually { !self.element(app, "settings.gsdSync.model.1").exists }, "a row goes")
        app.typeKey("w", modifierFlags: .command)
        app.terminate()

        let relaunched = launchSeeded(dataRoot: root)
        XCTAssertTrue(element(relaunched, "rightSidebar.tabs").waitForExistence(timeout: 10))
        openFeatures(relaunched)
        let kept = element(relaunched, "settings.gsdSync.model.0")
        XCTAssertTrue(kept.waitForExistence(timeout: 5))
        XCTAssertEqual(kept.value as? String, "anthropic/claude-sonnet-4", "the chain persists")
        XCTAssertFalse(element(relaunched, "settings.gsdSync.model.1").exists, "blank rows are not stored")
        relaunched.terminate()
    }

    /// Hit targets at three zoom levels: the tab, the row, the sheet's Done and the chain's buttons
    /// react where they are drawn.
    func testControlsReceiveClicksAtThreeZoomLevels() {
        for (steps, label) in [(-1, "90%"), (0, "100%"), (2, "120%")] {
            let app = launchSeeded()
            XCTAssertTrue(element(app, "rightSidebar.tabs").waitForExistence(timeout: 10))
            for _ in 0..<abs(steps) { app.typeKey(steps > 0 ? "+" : "-", modifierFlags: .command) }
            let tab = showGSDTab(app)
            XCTAssertTrue(eventually { (tab.value as? Int) == 1 }, "tab missed at \(label)")
            let row = element(app, "gsdSync.row.gsdrepo")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.click()
            XCTAssertTrue(element(app, "gsdActivity.sheet").waitForExistence(timeout: 5), "row missed at \(label)")
            element(app, "gsdActivity.done").click()
            XCTAssertTrue(eventually { !self.element(app, "gsdActivity.sheet").exists }, "Done missed at \(label)")

            openFeatures(app)
            element(app, "settings.gsdSync.add").click()
            XCTAssertTrue(element(app, "settings.gsdSync.model.0").waitForExistence(timeout: 5), "add missed at \(label)")
            element(app, "settings.gsdSync.remove.0").click()
            XCTAssertTrue(eventually { !self.element(app, "settings.gsdSync.model.0").exists }, "remove missed at \(label)")
            app.typeKey("w", modifierFlags: .command)
            app.terminate()
        }
    }
}
