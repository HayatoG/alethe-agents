import XCTest

/// Pairing sheet and remote toolbar pill (P7-19). The `remote` seed turns remote control on, bound to
/// 127.0.0.1 only.
@MainActor
final class RemotePairingTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func label(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    func testPillAppearsOnlyWhileRemoteControlIsOn() {
        let (off, _) = launchAlethe()
        XCTAssertTrue(element(off, "workspace.empty").waitForExistence(timeout: 5))
        XCTAssertFalse(element(off, "remote.toolbarPill").waitForExistence(timeout: 2), "no pill while off")
        off.terminate()

        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "remote"])
        let pill = element(app, "remote.toolbarPill")
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(eventually { self.label(pill).contains("Remote control on") }, "idle with no device")

        // Turning it off from the sheet removes the pill.
        pill.click()
        let toggle = element(app, "remote.pairing.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(element(app, "remote.pairing.disabledCard").waitForExistence(timeout: 5))
        element(app, "remote.pairing.done").click()
        XCTAssertTrue(eventually { !pill.exists }, "the pill leaves when remote control turns off")
        app.terminate()
    }

    func testOpeningPairingShowsAQRAndCountdown() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "remote"])
        let pill = element(app, "remote.toolbarPill")
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.click()

        XCTAssertTrue(element(app, "remote.pairing").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "remote.pairing.qr").waitForExistence(timeout: 5))
        let countdown = element(app, "remote.pairing.countdown")
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { self.label(countdown).contains("expires in") })
        let url = element(app, "remote.pairing.urlText")
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { self.label(url).contains("127.0.0.1") && self.label(url).contains("pair=") })
        XCTAssertTrue(element(app, "remote.pairing.noDevices").exists)

        let copy = element(app, "remote.pairing.copy")
        copy.click()
        XCTAssertTrue(eventually { self.label(copy).contains("Copied") })

        element(app, "remote.pairing.done").click()
        XCTAssertTrue(eventually { !self.element(app, "remote.pairing").exists })
        app.terminate()
    }

    /// HT: the pill and the sheet's buttons are clicked where they are drawn at 90 %, 100 % and 120 %.
    func testControlsReceiveClicksAtThreeZoomLevels() {
        for (zoom, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "remote"])
            let pill = element(app, "remote.toolbarPill")
            XCTAssertTrue(pill.waitForExistence(timeout: 10))
            for key in keys { app.typeKey(key, modifierFlags: .command) }

            pill.click()
            XCTAssertTrue(element(app, "remote.pairing").waitForExistence(timeout: 5), "pill missed at \(zoom)")
            let copy = element(app, "remote.pairing.copy")
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            copy.click()
            XCTAssertTrue(eventually { self.label(copy).contains("Copied") }, "copy missed at \(zoom)")
            element(app, "remote.pairing.done").click()
            XCTAssertTrue(eventually { !self.element(app, "remote.pairing").exists }, "done missed at \(zoom)")
            app.terminate()
        }
    }
}
