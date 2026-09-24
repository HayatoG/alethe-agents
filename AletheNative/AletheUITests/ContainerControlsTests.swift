import XCTest

/// Container controls (P2-16): collapse and expand, show a project alone, show a pane alone.
@MainActor
final class ContainerControlsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testCollapseFullscreenAndIsolate() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "panes"])
        XCTAssertTrue(element(app, "container.api").waitForExistence(timeout: 5))

        element(app, "container.collapse.api").click()
        XCTAssertTrue(element(app, "container.collapsed.api").waitForExistence(timeout: 5), "collapsed to a strip")
        element(app, "container.collapsed.api").click()
        XCTAssertTrue(element(app, "container.collapse.api").waitForExistence(timeout: 5), "expanded again")

        element(app, "container.fullscreen.web").click()
        XCTAssertTrue(eventually { !self.element(app, "container.api").exists }, "only web is shown")
        element(app, "container.fullscreen.web").click()
        XCTAssertTrue(element(app, "container.api").waitForExistence(timeout: 5), "all projects again")

        element(app, "pane.header.two").rightClick()
        app.menuItems["Show This Pane Alone"].click()
        XCTAssertTrue(eventually { !self.element(app, "pane.header.one").isHittable }, "one pane alone")
        XCTAssertTrue(eventually { !self.element(app, "container.web").exists })
        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "container.web").waitForExistence(timeout: 5), "⇧⌘↩ shows everything again")
        app.terminate()
    }
}
