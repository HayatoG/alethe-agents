import AletheAgents
import AletheModel

extension Router9 {
    /// Whether the New Terminal sheet offers "Route through 9router" (upstream `NewTerminalModal`
    /// `routingAvailable`): 9router on, keyed, installed, and the agent speaks a routed dialect.
    /// Without a key the routed environment would be empty and the toggle would do nothing.
    public static func routingAvailable(_ preferences: Router9Preferences, hasAPIKey: Bool, hasInstall: Bool,
                                        agent: AgentKind) -> Bool {
        preferences.enabled && hasAPIKey && hasInstall && supports(agent)
    }

    /// Variables a tab's launch adds (upstream `useXtermSession` `router9EnvFor`): only for a tab
    /// that asked for routing, and only while 9router is enabled and keyed (`config` nil otherwise).
    public static func launchEnvironment(for tab: PaneTab, config: Router9RoutingConfig?) -> [String: String] {
        guard tab.useRouter9 == true else { return [:] }
        return environment(for: AgentKind(rawValue: tab.agent), config: config)
    }

    /// Whether starting `tab` has to read the routing config (the Keychain) first.
    public static func wantsRouting(_ tab: PaneTab) -> Bool {
        tab.useRouter9 == true && supports(AgentKind(rawValue: tab.agent))
    }
}
