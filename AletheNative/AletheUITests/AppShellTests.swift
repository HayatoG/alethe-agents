import XCTest

@MainActor
final class AppShellTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testFirstLaunchShowsTheEmptyWorkspace() {
        let (app, _) = launchAlethe()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
        app.terminate()
    }

    /// Zoom scales the layout itself (the empty-state title grows) and survives a relaunch.
    func testZoomMenuChangesAndPersistsTheUIScale() {
        let (app, root) = launchAlethe()
        let empty = app.descendants(matching: .any)["workspace.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        let baseline = empty.frame.height
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Zoom In"].click()
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Zoom In"].click()
        XCTAssertTrue(eventually { empty.frame.height > baseline * 1.1 })
        let zoomed = empty.frame.height
        // XCUIApplication.terminate() kills the process; wait past the save debounce first.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        let again = relaunched.descendants(matching: .any)["workspace.empty"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.frame.height, zoomed, accuracy: 1)
        relaunched.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(eventually { abs(again.frame.height - baseline) < 1 })
        relaunched.terminate()
    }

    func testSettingsWindowSavesPreferences() {
        let (app, root) = launchAlethe()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.descendants(matching: .any)["settings.alwaysUnrestricted"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 0, "type=\(toggle.elementType.rawValue) value=\(String(describing: toggle.value))")
        toggle.click()
        XCTAssertTrue(eventually { toggle.value as? Int == 1 }, "value=\(String(describing: toggle.value))")
        // Past the save debounce, then relaunch.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        let (relaunched, _) = launchAlethe(dataRoot: root)
        XCTAssertTrue(relaunched.descendants(matching: .any)["workspace.empty"].waitForExistence(timeout: 5))
        relaunched.typeKey(",", modifierFlags: .command)
        let again = relaunched.descendants(matching: .any)["settings.alwaysUnrestricted"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "settings did not open after relaunch")
        XCTAssertEqual(again.value as? Int, 1)
        relaunched.terminate()
    }

    func testSidebarToggleHidesAndShowsTheSidebar() {
        let (app, _) = launchAlethe()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let sidebar = window.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(eventually { !sidebar.isHittable })
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(eventually { sidebar.isHittable })
        app.terminate()
    }
}
