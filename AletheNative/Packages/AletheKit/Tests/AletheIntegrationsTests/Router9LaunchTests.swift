import AletheAgents
import AletheModel
import Foundation
import Testing
@testable import AletheIntegrations

/// U (P7-17): 9router variables reaching a routed tab's launch (upstream `useXtermSession`
/// `router9EnvFor`), the sheet's availability rule, and repeat last keeping the choice.
struct Router9LaunchTests {
    static let launcher = AgentLauncher(launchers: LauncherCache(stillExists: { _ in true }),
                                        overrides: ["claude": "/bin/echo", "codex": "/bin/echo", "opencode": "/bin/echo",
                                                    "copilot": "/bin/echo"])
    static let config = Router9RoutingConfig(enabled: true, port: 20200, apiKey: "sk-secret")

    private func routed(_ agent: AgentKind) -> PaneTab {
        var tab = PaneTab(agent: agent.rawValue)
        tab.useRouter9 = true
        return tab
    }

    private func command(for tab: PaneTab, config: Router9RoutingConfig?) throws -> AgentCommand {
        let request = AgentLaunchRequest(kind: AgentKind(rawValue: tab.agent),
                                         environment: Router9.launchEnvironment(for: tab, config: config))
        return try Self.launcher.command(for: request, makeSessionID: { "new" })
    }

    @Test func claudeGetsAnthropicVariables() throws {
        let command = try command(for: routed(.claude), config: Self.config)
        #expect(command.environment["ANTHROPIC_BASE_URL"] == .some("http://127.0.0.1:20200"))
        #expect(command.environment["ANTHROPIC_AUTH_TOKEN"] == .some("sk-secret"))
        #expect(command.environment["OPENAI_API_KEY"] == nil)
    }

    @Test func codexAndOpenCodeGetOpenAIVariables() throws {
        for agent in [AgentKind.codex, .opencode] {
            let command = try command(for: routed(agent), config: Self.config)
            #expect(command.environment["OPENAI_BASE_URL"] == .some("http://127.0.0.1:20200/v1"))
            #expect(command.environment["OPENAI_API_KEY"] == .some("sk-secret"))
            #expect(command.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        }
    }

    @Test func theKeyNeverReachesTheCommandLine() throws {
        for agent in [AgentKind.claude, .codex, .opencode] {
            let command = try command(for: routed(agent), config: Self.config)
            #expect(command.shellCommand?.contains("sk-secret") == false)
        }
    }

    @Test func nothingWhenOffKeylessUnsupportedOrNotAsked() throws {
        let off = Router9RoutingConfig(enabled: false, apiKey: "sk-secret")
        let keyless = Router9RoutingConfig(enabled: true, apiKey: "  ")
        #expect(Router9.launchEnvironment(for: routed(.claude), config: nil).isEmpty)
        #expect(Router9.launchEnvironment(for: routed(.claude), config: off).isEmpty)
        #expect(Router9.launchEnvironment(for: routed(.codex), config: keyless).isEmpty)
        #expect(Router9.launchEnvironment(for: routed(.copilot), config: Self.config).isEmpty)
        #expect(Router9.launchEnvironment(for: PaneTab(agent: "claude"), config: Self.config).isEmpty)
        var declined = routed(.claude)
        declined.useRouter9 = false
        #expect(Router9.launchEnvironment(for: declined, config: Self.config).isEmpty)

        let plain = try command(for: routed(.claude), config: off)
        #expect(plain.environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(plain.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test func onlyRoutedSupportedTabsWaitForTheConfig() {
        #expect(Router9.wantsRouting(routed(.claude)))
        #expect(Router9.wantsRouting(routed(.opencode)))
        #expect(!Router9.wantsRouting(routed(.shell)))
        #expect(!Router9.wantsRouting(PaneTab(agent: "codex")))
    }

    @Test func toggleIsOfferedOnlyWhenRoutingCanApply() {
        let on = Router9Preferences(enabled: true)
        #expect(Router9.routingAvailable(on, hasAPIKey: true, hasInstall: true, agent: .claude))
        #expect(Router9.routingAvailable(on, hasAPIKey: true, hasInstall: true, agent: .codex))
        #expect(!Router9.routingAvailable(Router9Preferences(), hasAPIKey: true, hasInstall: true, agent: .claude))
        #expect(!Router9.routingAvailable(on, hasAPIKey: false, hasInstall: true, agent: .claude))
        #expect(!Router9.routingAvailable(on, hasAPIKey: true, hasInstall: false, agent: .claude))
        #expect(!Router9.routingAvailable(on, hasAPIKey: true, hasInstall: true, agent: .shell))
        #expect(!Router9.routingAvailable(on, hasAPIKey: true, hasInstall: true, agent: .copilot))
    }

    @Test func repeatLastKeepsTheChoice() throws {
        let creation = TerminalCreation(agent: "claude", useRouter9: true)
        #expect(creation.tab().useRouter9 == true)
        let decoded = try JSONDecoder().decode(TerminalCreation.self, from: JSONEncoder().encode(creation))
        #expect(decoded.useRouter9 == true)
        let older = try JSONDecoder().decode(TerminalCreation.self, from: Data(
            #"{"agent":"codex","unrestricted":false,"extraArguments":[]}"#.utf8))
        #expect(older.useRouter9 == nil && older.tab().useRouter9 == nil)
    }
}
