import AletheModel
import Testing
@testable import AletheIntegrations

/// U (P7-16): when a launch starts 9router on its own (upstream `useRouter9AutoStart`).
@Suite(.timeLimit(.minutes(1))) struct Router9AutoStartTests {
    private func status(managed: Bool = true, external: Bool = false, running: Bool = false,
                        portInUse: Bool = false) -> Router9Status {
        Router9Status(
            managed: managed ? Router9Install(installed: true, version: Router9.pinnedVersion) : .none,
            external: external ? Router9Install(installed: true, version: "0.5.40", path: "/opt/bin/9router") : .none,
            running: running, portInUse: portInUse, port: Router9.defaultPort, installDirectory: "",
            dataDirectory: "", logPath: "", dashboardURL: "")
    }

    private let on = Router9Preferences(enabled: true, autoStart: true)

    @Test func startsTheInstallWhenEnabledWithAutoStartAndAFreePort() {
        #expect(Router9.wantsAutoStart(on))
        #expect(Router9.autoStartSource(on, status: status()) == .managed)
    }

    @Test func nothingStartsWhenDisabledOrAutoStartIsOff() {
        let disabled = Router9Preferences(enabled: false, autoStart: true)
        let manual = Router9Preferences(enabled: true, autoStart: false)
        #expect(!Router9.wantsAutoStart(disabled))
        #expect(!Router9.wantsAutoStart(manual))
        #expect(!Router9.wantsAutoStart(Router9Preferences()))
        #expect(Router9.autoStartSource(disabled, status: status()) == nil)
        #expect(Router9.autoStartSource(manual, status: status()) == nil)
    }

    @Test func nothingStartsWithoutAnInstallOrStatus() {
        #expect(Router9.autoStartSource(on, status: status(managed: false)) == nil)
        #expect(Router9.autoStartSource(on, status: nil) == nil)
    }

    @Test func nothingStartsWhenItAlreadyRunsOrThePortIsTaken() {
        #expect(Router9.autoStartSource(on, status: status(running: true)) == nil)
        #expect(Router9.autoStartSource(on, status: status(portInUse: true)) == nil)
    }

    @Test func followsThePreferredSourceAndFallsBackToTheOther() {
        let external = Router9Preferences(enabled: true, autoStart: true, source: .external)
        #expect(Router9.autoStartSource(external, status: status(external: true)) == .external)
        #expect(Router9.autoStartSource(external, status: status(managed: true, external: false)) == .managed)
        #expect(Router9.autoStartSource(on, status: status(managed: false, external: true)) == .external)
    }

    @Test func routingConfigTakesTheKeyFromTheCallerAndThePortFromPreferences() {
        let preferences = Router9Preferences(enabled: true, port: 31000)
        let config = Router9RoutingConfig(preferences, apiKey: "9r_test")
        #expect(config == Router9RoutingConfig(enabled: true, port: 31000, apiKey: "9r_test"))
        #expect(Router9.environment(for: .claude, config: config)["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:31000")
        #expect(AletheIntegrations.Router9Source(AletheModel.Router9Source.external) == .external)
    }
}
