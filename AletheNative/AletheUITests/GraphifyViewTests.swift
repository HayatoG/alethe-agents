import XCTest

/// Graphify view (P5-23): Add Content › Code Graph opens the seeded repository's graph; search finds a
/// node, selecting it shows its details; a snapshot shows what changed since.
@MainActor
final class GraphifyViewTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testOpenSearchAndSelect() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "graphify"])
        XCTAssertTrue(app.staticTexts["graphrepo"].waitForExistence(timeout: 10))

        app.typeKey("a", modifierFlags: [.command, .shift])
        let option = element(app, "addContent.graphify")
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Add Content offers the code graph")
        option.click()
        XCTAssertTrue(element(app, "graphify.pane").waitForExistence(timeout: 5), "the graph pane opens")
        XCTAssertTrue(element(app, "graphify.canvas").waitForExistence(timeout: 15), "the graph is laid out")

        let search = element(app, "graphify.search")
        search.click()
        paste("delta", into: app)
        let result = element(app, "graphify.result.delta")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "search lists the node")
        result.click()
        XCTAssertTrue(element(app, "graphify.detail").waitForExistence(timeout: 5), "selecting shows the details")
        XCTAssertTrue(app.staticTexts["delta"].exists)

        element(app, "graphify.clearSelection").click()
        XCTAssertTrue(eventually { !self.element(app, "graphify.detail").exists }, "the selection clears")

        element(app, "graphify.snapshot.1750000000000").click()
        XCTAssertTrue(element(app, "graphify.diff").waitForExistence(timeout: 5), "the snapshot is compared")

        element(app, "graphify.rollback.1750000000000").click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "rollback asks first")
        app.buttons["Cancel"].click()
        XCTAssertTrue(element(app, "graphify.canvas").exists, "cancelling keeps the graph")
        app.terminate()
    }
}
