import AletheAgents
import Foundation

/// Which 9router install Alethe runs: the copy it manages in the profile, or one the user installed.
public enum Router9Source: String, Hashable, Sendable, Codable, CaseIterable {
    case managed
    case external
}

/// One place 9router can come from. `path` is set only for the external install.
public struct Router9Install: Hashable, Sendable {
    public var installed: Bool
    public var version: String?
    public var path: String?

    public init(installed: Bool = false, version: String? = nil, path: String? = nil) {
        self.installed = installed
        self.version = version
        self.path = path
    }

    public static let none = Router9Install()
}

/// Upstream `Router9Status`.
public struct Router9Status: Hashable, Sendable {
    /// The copy Alethe installed into its own profile folder.
    public var managed: Router9Install
    /// A 9router the user installed themselves, resolved through `LauncherResolver`.
    public var external: Router9Install
    /// The process this app started is still alive.
    public var running: Bool
    /// Something answers on the port. With `running` false another process owns it.
    public var portInUse: Bool
    public var port: Int
    public var installDirectory: String
    public var dataDirectory: String
    public var logPath: String
    public var dashboardURL: String
    public var pinnedVersion: String

    public init(managed: Router9Install, external: Router9Install, running: Bool, portInUse: Bool, port: Int,
                installDirectory: String, dataDirectory: String, logPath: String, dashboardURL: String,
                pinnedVersion: String = Router9.pinnedVersion) {
        self.managed = managed
        self.external = external
        self.running = running
        self.portInUse = portInUse
        self.port = port
        self.installDirectory = installDirectory
        self.dataDirectory = dataDirectory
        self.logPath = logPath
        self.dashboardURL = dashboardURL
        self.pinnedVersion = pinnedVersion
    }

    public func install(_ source: Router9Source) -> Router9Install {
        switch source {
        case .managed: managed
        case .external: external
        }
    }
}

/// The routing inputs of the 9router preferences. The API key comes from the Keychain (P7-1) and is
/// passed in by the caller; nothing here stores or logs it.
public struct Router9RoutingConfig: Hashable, Sendable {
    public var enabled: Bool
    public var port: Int
    public var apiKey: String

    public init(enabled: Bool, port: Int = Router9.defaultPort, apiKey: String) {
        self.enabled = enabled
        self.port = port
        self.apiKey = apiKey
    }
}

/// Pure 9router rules (upstream `lib/router9.ts`).
public enum Router9 {
    public static let pinnedVersion = "0.5.59"
    public static let defaultPort = 20128
    public static let package = "9router"
    public static let advisoriesURL = URL(string: "https://github.com/decolua/9router/security/advisories")!
    public static let docsURL = URL(string: "https://github.com/decolua/9router")!

    enum Dialect { case anthropic, openai }

    static func dialect(for agent: AgentKind) -> Dialect? {
        switch agent {
        case .claude: .anthropic
        case .codex, .opencode: .openai
        default: nil
        }
    }

    public static func supports(_ agent: AgentKind) -> Bool { dialect(for: agent) != nil }

    /// A port a listener can bind, else the default.
    public static func normalizePort(_ port: Int) -> Int {
        port > 0 && port < 65536 ? port : defaultPort
    }

    /// Preference values may arrive as JSON numbers: fractions fall back to the default.
    public static func normalizePort(_ port: Double) -> Int {
        guard port.isFinite, port.rounded() == port, port > 0, port < 65536 else { return defaultPort }
        return Int(port)
    }

    /// Always loopback: Alethe never routes through another host.
    public static func baseURL(port: Int) -> String { "http://127.0.0.1:\(normalizePort(port))" }

    public static func dashboardURL(port: Int) -> String { "\(baseURL(port: port))/dashboard" }

    /// Variables that point one agent at the local router; empty whenever routing must not apply,
    /// so the caller can always merge the result.
    public static func environment(for agent: AgentKind, config: Router9RoutingConfig?) -> [String: String] {
        guard let config, config.enabled else { return [:] }
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, let dialect = dialect(for: agent) else { return [:] }
        let base = baseURL(port: config.port)
        switch dialect {
        case .anthropic: return ["ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": apiKey]
        case .openai: return ["OPENAI_BASE_URL": "\(base)/v1", "OPENAI_API_KEY": apiKey]
        }
    }

    /// True when any 9router is available to route through, whichever install it is.
    public static func hasInstall(_ status: Router9Status?) -> Bool {
        guard let status else { return false }
        return status.managed.installed || status.external.installed
    }

    /// The install a start will use: the preferred one when it exists, else the other, nil when
    /// neither is installed.
    public static func resolveSource(_ status: Router9Status?, preferred: Router9Source)
        -> (source: Router9Source, install: Router9Install)? {
        guard let status else { return nil }
        let order: [Router9Source] = preferred == .external ? [.external, .managed] : [.managed, .external]
        for source in order where status.install(source).installed {
            return (source, status.install(source))
        }
        return nil
    }
}
