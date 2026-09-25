import XCTest

/// Merge Center and Branch Testing sheets open from the project menu (P4-10, P4-12).
@MainActor
final class MergeCenterTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchSeeded() -> (XCUIApplication, XCUIElement) {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        let project = app.descendants(matching: .any)["sidebar.project.scratch"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        return (app, project)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testProjectMenuOpensMergeCenterAtAnalyze() {
        let (app, project) = launchSeeded()
        project.rightClick()
        app.menuItems["Merge Center…"].click()
        XCTAssertTrue(element(app, "merge.center").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "merge.stages").waitForExistence(timeout: 5))
        element(app, "merge.close").click()
        XCTAssertTrue(eventually { !element(app, "merge.center").exists })
        app.terminate()
    }

    func testProjectMenuOpensBranchTesting() {
        let (app, project) = launchSeeded()
        project.rightClick()
        app.menuItems["Test Branch…"].click()
        XCTAssertTrue(element(app, "branchTest.sheet").waitForExistence(timeout: 5))
        element(app, "branchTest.close").click()
        XCTAssertTrue(eventually { !element(app, "branchTest.sheet").exists })
        app.terminate()
    }
}
