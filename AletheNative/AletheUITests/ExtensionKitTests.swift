import XCTest

/// P4-19: the sample third-party ExtensionKit extension (`Samples/AletheSampleExtension`, built by
/// build-for-testing through a target dependency) is discovered, asks for consent on first enable,
/// renders its sidebar tab from its own process, and a crash in it leaves Alethe running with a
/// "stopped" state and Reload. The app registers the sample with LaunchServices at launch
/// (`-AletheRegisterExtensionApp`); the system may still ask to approve it once (Manage Extensions).
@MainActor
final class ExtensionKitTests: XCTestCase {
    private static let sampleID = "com.kc1t.alethe.sample.sidebar"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// `<Products>/Debug/AletheUITests-Runner.app/Contents/PlugIns/AletheUITests.xctest` → the
    /// sample app next to the runner.
    private var sampleAppPath: String {
        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "AletheSample.app").path
    }

    private func launchWithSample() -> XCUIApplication {
        let (app, _) = launchAlethe(arguments: ["-AletheRegisterExtensionApp", sampleAppPath])
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        return app
    }

    /// Opens Settings › Plugins and waits until the sample's manifest has been read over XPC.
    private func openSampleRow(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Plugins"].firstMatch.click()
        let row = element(app, "extensions.\(Self.sampleID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the sample extension is discovered")
        XCTAssertTrue(eventually(timeout: 10) { row.isEnabled }, "its manifest arrives over XPC")
        return row
    }

    func testSampleAppearsAndFirstEnableAsksForConsent() {
        let app = launchWithSample()
        let toggle = openSampleRow(app)
        XCTAssertEqual(toggle.value as? Int, 0, "third-party extensions start disabled")

        toggle.click()
        let consent = element(app, "extensions.consent")
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "first enable shows the capability prompt")
        XCTAssertTrue(consent.staticTexts["storage"].exists, "the prompt lists the declared capability")
        element(app, "extensions.consent.deny").click()
        XCTAssertFalse(consent.exists)
        XCTAssertEqual(toggle.value as? Int, 0, "declining keeps it off")

        toggle.click()
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "asks again after a decline")
        element(app, "extensions.consent.allow").click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 1 })

        // Off and on again: consent is remembered, no prompt.
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 0 })
        toggle.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 1 })
        XCTAssertFalse(consent.exists, "no prompt once granted")
        app.terminate()
    }

    func testSampleTabRendersAndACrashIsContained() {
        let app = launchWithSample()
        let toggle = openSampleRow(app)
        toggle.click()
        let allow = element(app, "extensions.consent.allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.click()
        XCTAssertTrue(eventually { (toggle.value as? Int) == 1 })
        app.typeKey("w", modifierFlags: .command)

        app.typeKey("0", modifierFlags: [.command, .option])
        let tabs = element(app, "rightSidebar.tabs")
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.radioButtons["Sample"].firstMatch.click()
        XCTAssertTrue(element(app, "extensions.tab.\(Self.sampleID)").waitForExistence(timeout: 10),
                      "the host view controller is in the sidebar")

        // The remote scene: storage goes through the host.
        let counter = element(app, "sample.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "the extension's own view renders")
        element(app, "sample.increment").click()
        XCTAssertTrue(eventually { (counter.label + ((counter.value as? String) ?? "")).contains("1") },
                      "the counter was stored by the host")

        element(app, "sample.crash").click()
        let stopped = element(app, "extensions.stopped")
        XCTAssertTrue(stopped.waitForExistence(timeout: 10), "the crash shows the stopped state")
        XCTAssertEqual(app.state, .runningForeground, "Alethe keeps running")
        XCTAssertTrue(element(app, "rightSidebar.tabs").exists)

        element(app, "extensions.stopped.reload").click()
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "Reload brings the extension back")
        app.terminate()
    }
}
