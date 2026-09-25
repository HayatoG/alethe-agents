import XCTest

/// Workspace tabs and history (P2-17): a tab per opened project, back/forward, close and reopen.
@MainActor
final class WorkspaceTabsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testTabsHistoryAndReopen() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(element(app, "sidebar.project.alpha").waitForExistence(timeout: 5))

        element(app, "sidebar.project.alpha").click()
        XCTAssertTrue(element(app, "workspaceTabs.tab.alpha").waitForExistence(timeout: 5))
        element(app, "sidebar.project.beta").click()
        XCTAssertTrue(element(app, "workspaceTabs.tab.beta").waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { !self.element(app, "container.alpha").exists }, "beta replaces alpha in the view")

        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(element(app, "container.alpha").waitForExistence(timeout: 5), "⌘[ goes back to alpha")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(element(app, "container.beta").waitForExistence(timeout: 5), "⌘] goes forward to beta")

        element(app, "workspaceTabs.tab.alpha").click()
        XCTAssertTrue(element(app, "container.alpha").waitForExistence(timeout: 5), "clicking a tab shows it")

        // The close button shows on hover (or on the active tab).
        // The close button's accessibility frame is off screen (SwiftUI, inside the draggable tab):
        // click where it is drawn, at the tab's trailing edge.
        let tab = element(app, "workspaceTabs.tab.alpha")
        tab.hover()
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: tab.frame.width - 15, dy: 0)).click()
        XCTAssertTrue(eventually { !self.element(app, "workspaceTabs.tab.alpha").exists })
        XCTAssertTrue(element(app, "container.beta").waitForExistence(timeout: 5), "the remaining tab is shown")
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "workspaceTabs.tab.alpha").waitForExistence(timeout: 5), "⇧⌘T reopens it")
        XCTAssertTrue(element(app, "container.alpha").waitForExistence(timeout: 5))
        app.terminate()
    }
}
