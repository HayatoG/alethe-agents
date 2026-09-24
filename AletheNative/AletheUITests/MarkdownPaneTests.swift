import XCTest

/// Markdown pane (P2-9): rendered file, edit and save, reload, close with undo; header hit targets.
@MainActor
final class MarkdownPaneTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testRendersEditsSavesAndCloses() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "markdown"])
        XCTAssertTrue(element(app, "markdown.rendered").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Seeded"].waitForExistence(timeout: 5), "the heading is rendered")

        element(app, "markdown.edit").click()
        let editor = app.textViews["markdown.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        // No lowercase "c" (XCUITest drops it on the owner's layout).
        editor.typeText("# Updated\n")
        element(app, "markdown.save").click()
        XCTAssertTrue(app.staticTexts["Updated"].waitForExistence(timeout: 5), "saved text is rendered")

        element(app, "pane.close").click()
        XCTAssertTrue(eventually { !self.element(app, "markdown.pane").exists })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(element(app, "markdown.pane").waitForExistence(timeout: 5), "closing is undoable")
        app.terminate()
    }

    /// HT: header buttons at 90 %, 100 % and 120 %.
    func testHeaderButtonsReceiveClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "markdown"])
            XCTAssertTrue(element(app, "markdown.rendered").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            element(app, "markdown.edit").click()
            XCTAssertTrue(app.textViews["markdown.editor"].waitForExistence(timeout: 5), "edit missed at \(label)")
            element(app, "markdown.cancelEdit").click()
            XCTAssertTrue(element(app, "markdown.rendered").waitForExistence(timeout: 5), "cancel missed at \(label)")
            element(app, "pane.close").click()
            XCTAssertTrue(eventually { !self.element(app, "markdown.pane").exists }, "close missed at \(label)")
            app.terminate()
        }
    }
}
