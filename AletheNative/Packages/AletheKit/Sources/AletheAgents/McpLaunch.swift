import Foundation

/// One stdio MCP server added to a single agent launch (P5-4). Integrations (Graphify, ai-memory,
/// Playwright) contribute these; nothing is written into the user's or the project's own config.
public struct McpLaunchServer: Equatable, Sendable {
    public var name: String
    public var command: String
    public var arguments: [String]
    /// Secrets may live here: they only reach private (0600) per-launch files or the child's argv.
    public var environment: [String: String]

    public init(name: String, command: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    /// First server of each name wins, in order.
    public static func deduplicated(_ servers: [McpLaunchServer]) -> [McpLaunchServer] {
        var seen: Set<String> = []
        return servers.filter { seen.insert($0.name).inserted }
    }
}

/// How each agent takes per-launch MCP servers. Upstream wrote `.codex/config.toml` and the project's
/// `opencode.json`; here Claude gets `--mcp-config <file>` (upstream `*_mcp_config_path`), Codex
/// `-c mcp_servers.<name>.…` overrides, and OpenCode `OPENCODE_CONFIG=<file>`, which OpenCode merges
/// between the global and the project config (verified against OpenCode 1.18 `Config.loadInstanceState`).
public enum McpLaunchConfig {
    /// Agents with per-launch MCP wiring.
    public static func supports(_ kind: AgentKind) -> Bool {
        kind == .claude || kind == .codex || kind == .opencode
    }

    /// Whether the agent reads the servers from a file the app writes before the launch.
    public static func needsFile(_ kind: AgentKind) -> Bool {
        kind == .claude || kind == .opencode
    }

    /// The per-launch file's contents for `kind`, or nil when it takes none.
    public static func file(for kind: AgentKind, servers: [McpLaunchServer]) -> Data? {
        switch kind {
        case .claude: claudeConfig(servers)
        case .opencode: opencodeConfig(servers)
        default: nil
        }
    }

    /// Claude Code `--mcp-config` file: `{"mcpServers": {name: {command, args, env}}}`.
    public static func claudeConfig(_ servers: [McpLaunchServer]) -> Data {
        var entries: [String: Any] = [:]
        for server in McpLaunchServer.deduplicated(servers) {
            var entry: [String: Any] = ["command": server.command, "args": server.arguments]
            if !server.environment.isEmpty { entry["env"] = server.environment }
            entries[server.name] = entry
        }
        return json(["mcpServers": entries])
    }

    /// OpenCode config layered through `OPENCODE_CONFIG`: `mcp.<name>` local servers (upstream's
    /// `opencode.json` entry shape).
    public static func opencodeConfig(_ servers: [McpLaunchServer]) -> Data {
        var entries: [String: Any] = [:]
        for server in McpLaunchServer.deduplicated(servers) {
            var entry: [String: Any] = ["type": "local", "command": [server.command] + server.arguments, "enabled": true]
            if !server.environment.isEmpty { entry["environment"] = server.environment }
            entries[server.name] = entry
        }
        return json(["$schema": "https://opencode.ai/config.json", "mcp": entries])
    }

    /// Codex `-c` overrides, one table per server. Codex splits the key path on dots without
    /// honoring quotes, so a name outside `[A-Za-z0-9_-]` is made into one.
    public static func codexArguments(_ servers: [McpLaunchServer]) -> [String] {
        var arguments: [String] = []
        var seen: Set<String> = []
        for server in servers {
            let key = codexKey(server.name)
            guard seen.insert(key).inserted else { continue }
            let prefix = "mcp_servers.\(key)"
            arguments += ["-c", "\(prefix).command=\(tomlString(server.command))"]
            arguments += ["-c", "\(prefix).args=[\(server.arguments.map(tomlString).joined(separator: ","))]"]
            if !server.environment.isEmpty {
                let pairs = server.environment.sorted { $0.key < $1.key }
                    .map { "\(tomlString($0.key))=\(tomlString($0.value))" }
                arguments += ["-c", "\(prefix).env={\(pairs.joined(separator: ","))}"]
            }
        }
        return arguments
    }

    static func codexKey(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let key = String(name.map { allowed.contains($0) ? $0 : "_" })
        return key.isEmpty ? "_" : key
    }

    /// A TOML basic string.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
