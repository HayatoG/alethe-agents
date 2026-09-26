import AppKit
import XCTest

/// Now Playing (P7-14): the seeded track on Home and in the sidebar, the last track after a relaunch,
/// Settings › Integrations › Spotify, and the Home connect prompt's hit target. Seeds replace the
/// Spotify service with an in-memory stand-in: no test reaches Spotify or opens a browser.
@MainActor
final class NowPlayingTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func showHome(_ app: XCUIApplication) {
        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "home").waitForExistence(timeout: 5))
    }

    func testSeededTrackOnHomeAndInSidebar() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "spotify"])
        let row = element(app, "sidebar.nowPlaying")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the sidebar footer shows the track")
        XCTAssertTrue(row.label.contains("Seeded Track"))
        XCTAssertFalse(row.label.contains("paused"))

        showHome(app)
        let track = element(app, "home.nowPlaying.track")
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Seeded Track"].exists)
        XCTAssertTrue(app.staticTexts["Seeded Artist, Second Artist"].exists)
        XCTAssertTrue(element(app, "home.nowPlaying.progress").exists)
        XCTAssertTrue(element(app, "home.nowPlaying.open").exists)
        app.terminate()
    }

    func testLastTrackShownPausedAfterRelaunch() {
        let (first, dataRoot) = launchAlethe(arguments: ["-AletheUITestSeed", "spotify"])
        XCTAssertTrue(element(first, "sidebar.nowPlaying").waitForExistence(timeout: 10))
        // The kept copy is written off the main thread right after the fetch.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        first.terminate()

        // Without the seed the stand-in is gone and nothing is connected: only the kept track shows.
        let (app, _) = launchAlethe(dataRoot: dataRoot)
        let row = element(app, "sidebar.nowPlaying")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the last track is restored")
        XCTAssertTrue(row.label.contains("Seeded Track"))
        XCTAssertTrue(row.label.contains("paused"))
        showHome(app)
        XCTAssertTrue(element(app, "home.nowPlaying.track").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Last track"].exists || app.staticTexts["LAST TRACK"].exists)
        app.terminate()
    }

    func testSettingsSectionConnectsAndDisconnects() {
        let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "spotifyOff"])
        XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Integrations"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()

        let clientID = element(app, "settings.spotify.clientID")
        XCTAssertTrue(clientID.waitForExistence(timeout: 5))
        XCTAssertEqual(clientID.value as? String, "seeded-client-id")
        XCTAssertTrue(element(app, "settings.spotify.secret").exists)
        XCTAssertTrue(element(app, "settings.spotify.redirect").exists)
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:8888/callback"].exists)
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 5))

        element(app, "settings.spotify.copy").click()
        XCTAssertTrue(eventually { NSPasteboard.general.string(forType: .string) == "http://127.0.0.1:8888/callback" })

        element(app, "settings.spotify.connect").click()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        let disconnect = element(app, "settings.spotify.disconnect")
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.click()
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings.spotify.connect").waitForExistence(timeout: 5))
        app.terminate()
    }

    /// HT: Home's Connect is clicked where it is drawn at 90 %, 100 % and 120 %.
    func testHomeConnectReceivesClicksAtThreeZoomLevels() {
        for (label, keys) in [("90 %", ["-"]), ("100 %", []), ("120 %", ["+", "+"])] {
            let (app, _) = launchAlethe(arguments: ["-AletheUITestSeed", "spotifyOff"])
            XCTAssertTrue(element(app, "workspace.empty").waitForExistence(timeout: 5))
            for key in keys { app.typeKey(key, modifierFlags: .command) }
            showHome(app)
            let connect = element(app, "home.nowPlaying.connect")
            XCTAssertTrue(connect.waitForExistence(timeout: 10), "the connect prompt shows at \(label)")
            connect.click()
            XCTAssertTrue(element(app, "home.nowPlaying.track").waitForExistence(timeout: 5), "Connect missed at \(label)")
            app.terminate()
        }
    }
}
