/// Which browser the Playwright MCP server drives (upstream `playwrightBrowserMode`).
public enum PlaywrightBrowserMode: String, CaseIterable, Codable, Sendable {
    /// Attaches to the browser Alethe owns, when one is running; every agent shares its tabs.
    case shared
    /// Playwright launches a separate browser of its own for each agent.
    case dedicated
}

/// The `npx -y @playwright/mcp@latest` server added to agent launches (upstream `mcp_server_spec_for`).
public enum PlaywrightMcp {
    public static let serverName = "playwright"
    public static let command = "npx"
    public static let package = "@playwright/mcp@latest"

    /// `endpoint` attaches to a running browser; without one, `dedicatedHeadless == true` asks for a
    /// headless browser of Playwright's own and anything else leaves its default (headed). Attaching
    /// wins over the headless flag: there is no such flag for a browser Playwright did not launch.
    public static func arguments(endpoint: String?, dedicatedHeadless: Bool?) -> [String] {
        var arguments = ["-y", package]
        if let endpoint {
            arguments += ["--cdp-endpoint", endpoint]
        } else if dedicatedHeadless == true {
            arguments.append("--headless")
        }
        return arguments
    }

    /// The arguments for one launch. Never starts a browser: shared mode attaches only when the shared
    /// browser already runs and otherwise leaves Playwright on its default, which opens a browser only
    /// once the agent reaches for one. Dedicated mode never attaches.
    public static func arguments(mode: PlaywrightBrowserMode, dedicatedHeadless: Bool,
                                 sharedEndpoint: String?) -> [String] {
        switch mode {
        case .shared: arguments(endpoint: sharedEndpoint, dedicatedHeadless: nil)
        case .dedicated: arguments(endpoint: nil, dedicatedHeadless: dedicatedHeadless)
        }
    }
}
