import XCTest

@MainActor
final class SidebarTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchSeeded() -> XCUIApplication {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "sidebar"])
        XCTAssertTrue(row(app, "project", "scratch").waitForExistence(timeout: 5))
        return app
    }

    private func row(_ app: XCUIApplication, _ kind: String, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.\(kind).\(name)"].firstMatch
    }

    /// Indentation of a row: deeper levels start further right.
    private func indent(_ element: XCUIElement) -> CGFloat { element.frame.minX }

    func testTreeShowsNestedGroups() {
        let app = launchSeeded()
        let work = row(app, "group", "Work"), clients = row(app, "group", "Clients")
        let site = row(app, "project", "client-site"), scratch = row(app, "project", "scratch")
        XCTAssertLessThan(indent(work), indent(clients))
        XCTAssertLessThan(indent(clients), indent(site))
        XCTAssertLessThan(indent(scratch), indent(site))
        app.terminate()
    }

    // Drag and drop is covered by Scripts/smoke/sidebar-drag.sh: XCUITest's synthesized drags do not
    // start a SwiftUI drag session on macOS, while real mouse events do.

    func testMoveToGroupMenuAndUndo() {
        let app = launchSeeded()
        let site = row(app, "project", "client-site")
        let nested = indent(site)
        site.rightClick()
        app.menuItems["Move to Group"].click()
        app.menuItems["No Group"].click()
        XCTAssertTrue(eventually { indent(row(app, "project", "client-site")) < nested })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(eventually { abs(indent(row(app, "project", "client-site")) - nested) < 1 })
        app.terminate()
    }

    func testDeletingAGroupKeepsItsProjects() {
        let app = launchSeeded()
        let site = row(app, "project", "client-site")
        let nested = indent(site)
        row(app, "group", "Clients").rightClick()
        app.menuItems["Delete Group"].click()
        XCTAssertTrue(eventually { !row(app, "group", "Clients").exists })
        XCTAssertTrue(row(app, "project", "client-site").exists)
        XCTAssertLessThan(indent(row(app, "project", "client-site")), nested)
        app.terminate()
    }

    func testAddProjectOpensAFolderPanel() {
        let app = launchSeeded()
        app.descendants(matching: .any)["sidebar.addProject"].firstMatch.click()
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(eventually { app.sheets.count + app.dialogs.count > 0 || app.windows.count > 1 })
        app.typeKey(.escape, modifierFlags: [])
        _ = panel
        app.terminate()
    }
}
