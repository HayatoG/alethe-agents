import XCTest

/// History › Skills… (P5-15) over a seeded throwaway home (`-AletheUITestSeed skills` with
/// `-AletheIntegrationsHome`): list, filter, detail, and removing a linked skill keeps the shared copy.
@MainActor
final class SkillsBrowserTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchWithSkills() -> XCUIApplication {
        let root = makeTemporaryDataRoot()
        let (app, _) = launchAlethe(dataRoot: root, arguments: [
            "-AletheUITestSeed", "skills",
            "-AletheIntegrationsHome", root.appending(path: "home").path,
        ])
        return app
    }

    private func openSkills(_ app: XCUIApplication) -> XCUIElement {
        app.menuBars.menuBarItems["History"].click()
        app.menuItems["Skills…"].click()
        let sheet = element(app, "skills.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        return sheet
    }

    func testListsFiltersAndShowsTheDetail() {
        let app = launchWithSkills()
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        _ = openSkills(app)

        XCTAssertTrue(element(app, "skills.list").waitForExistence(timeout: 5))
        for name in ["brand", "imagegen", "motion"] {
            XCTAssertTrue(element(app, "skills.row.\(name)").exists, "\(name) is listed")
        }

        element(app, "skills.row.motion").click()
        XCTAssertTrue(app.staticTexts["Motion guide"].waitForExistence(timeout: 5), "SKILL.md is rendered")
        XCTAssertTrue(app.staticTexts["Creates motion graphics"].exists, "the folded description is joined")
        XCTAssertTrue(element(app, "skills.files").exists)
        XCTAssertTrue(element(app, "skills.remove").exists)

        // Bundled: no remove.
        element(app, "skills.row.imagegen").click()
        XCTAssertTrue(app.staticTexts["Images"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "skills.remove").exists)

        element(app, "skills.filter").click()
        paste("bran", into: app)
        XCTAssertTrue(eventually { !self.element(app, "skills.row.motion").exists })
        XCTAssertTrue(element(app, "skills.row.brand").exists)

        element(app, "skills.done").click()
        XCTAssertTrue(eventually { !self.element(app, "skills.sheet").exists })
        app.terminate()
    }

    func testRemovingALinkedSkillKeepsTheSharedCopy() {
        let app = launchWithSkills()
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        _ = openSkills(app)

        element(app, "skills.row.brand").click()
        XCTAssertTrue(app.staticTexts["Brand"].waitForExistence(timeout: 5))
        let remove = element(app, "skills.remove.claude")
        XCTAssertTrue(remove.exists, "Claude Code's link can go")
        XCTAssertFalse(element(app, "skills.remove.shared").exists, "the shared copy stays while an agent links it")
        remove.click()
        let confirm = element(app, "skills.remove.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks once")
        confirm.click()

        let note = element(app, "skills.note")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue((note.value as? String ?? note.label).contains("shared copy was kept"))
        // Only the shared store has it now.
        XCTAssertTrue(eventually { !self.element(app, "skills.remove.claude").exists })
        XCTAssertTrue(element(app, "skills.row.brand").exists)
        app.terminate()
    }

    func testTurningMCPOffHidesTheMenuItem() {
        let app = launchWithSkills()
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["History"].click()
        XCTAssertTrue(app.menuItems["Skills…"].exists, "on by default")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Features"].firstMatch.click()
        let toggle = element(app, "settings.feature.mcp")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 0 })
        app.typeKey("w", modifierFlags: .command)

        app.menuBars.menuBarItems["History"].click()
        XCTAssertFalse(app.menuItems["Skills…"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}
