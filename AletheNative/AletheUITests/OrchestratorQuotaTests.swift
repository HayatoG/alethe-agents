import XCTest

/// The board header's spend and quota chips (P6-17) over the P6-14 board seed, with usage seeded by
/// `-AletheUITestUsage` so nothing reaches the network, a CLI or the Keychain.
@MainActor
final class OrchestratorQuotaTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testSeededUsageShowsTheQuotaChipAndSpend() {
        let app = launchAlethe(arguments: ["-AletheUITestSeed", "orchestratorBoard",
                                           "-AletheUITestUsage", "claude:40,codex:92"]).0
        XCTAssertTrue(element(app, "orchestrator.pane").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "orchestrator.tab.tab-lead").waitForExistence(timeout: 10))

        // Codex at 92 % is past the threshold; Claude at 40 % is not.
        let codex = element(app, "orchestrator.quota.codex")
        XCTAssertTrue(codex.waitForExistence(timeout: 10), "the feed reads right away when a board opens")
        XCTAssertTrue(codex.label.contains("92%") || (codex.value as? String ?? "").contains("92%"))
        XCTAssertFalse(element(app, "orchestrator.quota.claude").exists)

        // The selected planner's spend: its Codex worker reported tokens but no price.
        let spend = element(app, "orchestrator.spend.codex")
        XCTAssertTrue(spend.exists)
        XCTAssertTrue(spend.label.contains("no price") || (spend.value as? String ?? "").contains("no price"))
        XCTAssertFalse(element(app, "orchestrator.spend.claude").exists, "a worker without tokens or price adds no spend")
        app.terminate()
    }
}
