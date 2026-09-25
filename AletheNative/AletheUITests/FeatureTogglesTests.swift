import XCTest

/// Settings › Features (P5-3): turning a feature off hides its surfaces.
@MainActor
final class FeatureTogglesTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testTurningPullRequestsOffHidesTheTab() {
        // The right sidebar open from launch, whatever the real defaults say.
        let (app, root) = launchAlethe(arguments: ["-main.rightSidebarVisible", "YES"])
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        let tabs = element(app, "rightSidebar.tabs")
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.radioButtons["Pull Requests"].exists, "on by default")

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Features"].firstMatch.click()
        let toggle = element(app, "settings.feature.prs")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 0 })
        XCTAssertFalse(element(app, "settings.feature.aiMemory").exists, "secondary features wait under Show More")
        element(app, "settings.features.showMore").click()
        XCTAssertTrue(element(app, "settings.feature.aiMemory").waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(eventually { !tabs.radioButtons["Pull Requests"].exists }, "the tab is gone")
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root, arguments: ["-main.rightSidebarVisible", "YES"])
        let again = element(relaunched, "rightSidebar.tabs")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertFalse(again.radioButtons["Pull Requests"].exists, "the choice persists")
        relaunched.terminate()
    }
}
