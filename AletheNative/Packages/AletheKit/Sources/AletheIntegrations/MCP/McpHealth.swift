import AletheAgents
import Foundation

// Port of upstream `mcp_health.rs`: each agent's `mcp list` read per server. Only a name and a status
// leave this file; the command, URL and arguments the CLIs print can carry tokens.

public enum McpHealthStatus: String, Hashable, Sendable, Codable {
    case connected
    case failed
    case needsAuth
    case disabled
    case unknown
}

public struct McpHealth: Hashable, Sendable, Codable {
    public var name: String
    public var status: McpHealthStatus

    public init(name: String, status: McpHealthStatus) {
        self.name = name
        self.status = status
    }
}

public enum McpHealthError: Error, Hashable, Sendable {
    /// Antigravity and Cursor are config-only: no CLI output to read a status from.
    case unsupportedAgent
    case cliNotFound
    case cliFailed
    case timedOut
    case cancelled
}

public enum McpHealthParser {
    /// `claude mcp list` renders one line per server, health-checked, as
    /// `name: <target> - <marker> <label>`. Only the marker is read.
    public static func parseClaude(_ stdout: String) -> [McpHealth] {
        stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...]
            guard !name.isEmpty, let separator = rest.range(of: " - ", options: .backwards) else { return nil }
            let tail = rest[separator.upperBound...].lowercased()
            let status: McpHealthStatus
            if tail.contains("connected") {
                status = .connected
            } else if tail.contains("auth") {
                status = .needsAuth
            } else if tail.contains("failed") || tail.contains("error") {
                status = .failed
            } else {
                status = .unknown
            }
            return McpHealth(name: name, status: status)
        }
    }

    /// `codex mcp list --json` reports configuration, not a live probe: it can only say that a
    /// server is disabled or unauthenticated.
    public static func parseCodex(_ stdout: String) -> [McpHealth] {
        guard let items = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [Any] else { return [] }
        return items.compactMap { raw in
            guard let item = raw as? [String: Any], let name = item["name"] as? String else { return nil }
            let enabled = (item["enabled"] as? Bool) ?? true
            let auth = ((item["auth_status"] as? String) ?? "").lowercased()
            let status: McpHealthStatus
            if !enabled {
                status = .disabled
            } else if auth.contains("unauthenticated") || auth.contains("needs") {
                status = .needsAuth
            } else {
                status = .unknown
            }
            return McpHealth(name: name, status: status)
        }
    }

    /// `opencode mcp list` draws a box; each server line is `●  ✓ <name> <state>`.
    public static func parseOpencode(_ stdout: String) -> [McpHealth] {
        let decoration: Set<Character> = ["┌", "│", "└", "●", "─", " "]
        return stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { raw in
            let trimmed = raw.drop(while: { decoration.contains($0) })
            guard let space = trimmed.firstIndex(of: " ") else { return nil }
            var status: McpHealthStatus
            switch trimmed[..<space] {
            case "✓": status = .connected
            case "✗", "✕", "×": status = .failed
            default: return nil
            }
            let rest = trimmed[trimmed.index(after: space)...]
            guard let name = rest.split(whereSeparator: \.isWhitespace).first, !name.isEmpty else { return nil }
            if rest.lowercased().contains("auth") { status = .needsAuth }
            return McpHealth(name: String(name), status: status)
        }
    }

    /// The CLI and arguments that list an agent's servers; nil when the agent has none to read.
    public static func cli(for agent: McpAgent) -> (binary: String, arguments: [String])? {
        switch agent {
        case .claude: ("claude", ["mcp", "list"])
        case .codex: ("codex", ["mcp", "list", "--json"])
        case .opencode: ("opencode", ["mcp", "list"])
        // `agy` has no mcp subcommand, and `cursor-agent mcp list` has no stable output contract.
        case .antigravity, .cursor: nil
        }
    }

    public static func parse(_ stdout: String, for agent: McpAgent) -> [McpHealth] {
        switch agent {
        case .claude: parseClaude(stdout)
        case .codex: parseCodex(stdout)
        case .opencode: parseOpencode(stdout)
        case .antigravity, .cursor: []
        }
    }
}

/// Upstream `mcp_health_check`: opt-in and one agent at a time, since `claude mcp list` connects to
/// every server it knows. Runs off the main thread, cancelable, with a 45 s timeout.
public struct McpHealthChecker: Sendable {
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: Duration)
        async throws(ExternalCommandError) -> ExternalCommandResult

    public static let timeout: Duration = .seconds(45)

    private let resolve: @Sendable (String) -> String?
    private let run: Runner
    private let timeout: Duration

    public init(
        resolve: @escaping @Sendable (String) -> String? = { LauncherResolver().resolve($0) },
        timeout: Duration = McpHealthChecker.timeout,
        run: @escaping Runner = { (executable: String, arguments: [String], timeout: Duration) async throws(ExternalCommandError) -> ExternalCommandResult in
            try await ExternalCommand.run(executable, arguments, timeout: timeout)
        }
    ) {
        self.resolve = resolve
        self.timeout = timeout
        self.run = run
    }

    /// Upstream reads stdout whatever the exit status: `claude mcp list` exits non-zero when a
    /// server fails to connect and still lists every server.
    @concurrent
    public func check(_ agent: McpAgent) async throws(McpHealthError) -> [McpHealth] {
        guard let cli = McpHealthParser.cli(for: agent) else { throw .unsupportedAgent }
        guard let executable = resolve(cli.binary) else { throw .cliNotFound }
        let result: ExternalCommandResult
        do {
            result = try await run(executable, cli.arguments, timeout)
        } catch {
            switch error {
            case .timedOut: throw .timedOut
            case .cancelled: throw .cancelled
            case .launchFailed: throw .cliFailed
            }
        }
        return McpHealthParser.parse(result.stdout, for: agent)
    }
}
