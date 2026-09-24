import XCTest

/// Link preview (P2-14): a Markdown file renders in the sheet and Esc closes it.
@MainActor
final class LinkPreviewTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testMarkdownPreviewRendersAndEscCloses() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "markdown", "-AletheUITestPreview", "README.md"])
        let sheet = app.descendants(matching: .any)["linkPreview"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["Seeded"].waitForExistence(timeout: 5), "the Markdown is rendered")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !sheet.exists }, "Esc closes the preview")
        app.terminate()
    }
}
