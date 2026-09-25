import AletheFoundation
import Foundation

/// Codex: `[mcp_servers.<name>]` in `~/.codex/config.toml` or `<repo>/.codex/config.toml`, edited
/// through `TOMLDocument` so comments and every other table keep their bytes (upstream `toml_edit`).
public struct CodexMcpAdapter: McpAdapter {
    public init() {}
    public var agent: McpAgent { .codex }

    /// Keys rewritten on every upsert; `enabled`, `env` and `env_vars` are handled on their own.
    static let managedKeys = [
        "command", "args", "cwd", "url", "bearer_token_env_var", "startup_timeout_sec", "tool_timeout_sec",
    ]

    public func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource] {
        switch scope {
        case .global:
            return [McpSource(url: home.path(".codex", "config.toml"), kind: .user)]
        case .project:
            guard let repository else { return [] }
            return [McpSource(url: repository.appending(path: ".codex/config.toml", directoryHint: .notDirectory), kind: .project)]
        }
    }

    public func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        guard !text.allSatisfy(\.isWhitespace) else { return [] }
        let document = try Self.document(text)
        guard let servers = document.table(at: ["mcp_servers"]) else { return [] }
        return servers.entries.compactMap { entry in
            entry.value.tableValue.map { Self.server(entry.key, $0) }
        }.sorted { $0.name < $1.name }
    }

    static func server(_ name: String, _ table: TOMLTable) -> McpServer {
        let transport: McpTransport
        if let url = table["url"]?.stringValue {
            transport = .http(url: url, headers: [:])
        } else {
            transport = .stdio(
                command: table["command"]?.stringValue ?? "",
                arguments: table["args"]?.stringArrayValue ?? [],
                cwd: table["cwd"]?.stringValue
            )
        }
        var env: McpEnvMap = [:]
        for entry in table["env"]?.tableValue?.entries ?? [] {
            if let text = entry.value.stringValue { env[entry.key] = .literal(text) }
        }
        for variable in table["env_vars"]?.stringArrayValue ?? [] {
            env[variable, default: McpEnvEntry()].passthroughFrom = variable
        }
        return McpServer(
            name: name,
            transport: transport,
            env: env,
            enabled: table["enabled"]?.boolValue ?? true,
            timeouts: McpTimeouts(startupSeconds: seconds(table["startup_timeout_sec"]),
                                  toolSeconds: seconds(table["tool_timeout_sec"])),
            bearerTokenEnvVar: table["bearer_token_env_var"]?.stringValue
        )
    }

    /// Integer or float seconds; negative or non-finite values are ignored, large ones saturate.
    static func seconds(_ value: TOMLValue?) -> UInt32? {
        switch value {
        case .integer(let number)?: return UInt32(exactly: number)
        case .float(let number)? where number.isFinite && number >= 0:
            return UInt32(clamping: Int64(min(number.rounded(), Double(UInt32.max))))
        default: return nil
        }
    }

    public func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        var document = try Self.document(text)
        let path = ["mcp_servers", server.name]
        var entry = document.table(at: path) ?? TOMLTable(style: .section)
        for key in Self.managedKeys { entry[key] = nil }

        switch server.transport {
        case .stdio(let command, let arguments, let cwd):
            entry["command"] = .string(command)
            if !arguments.isEmpty { entry["args"] = .array(arguments.map(TOMLValue.string)) }
            if let cwd { entry["cwd"] = .string(cwd) }
        case .http(let url, _), .sse(let url, _):
            entry["url"] = .string(url)
        }
        if let variable = server.bearerTokenEnvVar { entry["bearer_token_env_var"] = .string(variable) }
        if let seconds = server.timeouts.startupSeconds { entry["startup_timeout_sec"] = .integer(Int64(seconds)) }
        if let seconds = server.timeouts.toolSeconds { entry["tool_timeout_sec"] = .integer(Int64(seconds)) }
        entry["enabled"] = server.enabled ? nil : .boolean(false)
        Self.setEnv(&entry, server.env)

        try Self.edit(&document) { try $0.upsertTable(entry, at: path) }
        return document.text
    }

    /// A new `env` is written inline; an existing one keeps its container (a hand-written
    /// `[mcp_servers.x.env]` section stays a section).
    static func setEnv(_ entry: inout TOMLTable, _ env: McpEnvMap) {
        let sorted = env.sorted { $0.key < $1.key }
        let literals = sorted.compactMap { key, item in item.literal.map { (key, TOMLValue.string($0)) } }
        let passthrough = sorted.compactMap { $0.value.passthroughFrom }
        if literals.isEmpty {
            entry["env"] = nil
        } else {
            entry["env"] = .table(TOMLTable(literals, style: entry["env"]?.tableValue?.style ?? .inline))
        }
        entry["env_vars"] = passthrough.isEmpty ? nil : .array(passthrough.map(TOMLValue.string))
    }

    public func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        var document = try Self.document(text)
        guard document.table(at: ["mcp_servers", name]) != nil else { throw .notFound }
        try Self.edit(&document) { try $0.removeTable(at: ["mcp_servers", name]) }
        return document.text
    }

    public func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String {
        var document = try Self.document(text)
        guard document.table(at: ["mcp_servers", name]) != nil else { throw .notFound }
        try Self.edit(&document) { try $0.setValue(.boolean(enabled), forKey: "enabled", inTableAt: ["mcp_servers", name]) }
        return document.text
    }

    static func document(_ text: String) throws(McpConfigError) -> TOMLDocument {
        do {
            return try TOMLDocument(parsing: text)
        } catch {
            throw map(error)
        }
    }

    static func edit(_ document: inout TOMLDocument, _ body: (inout TOMLDocument) throws -> Void) throws(McpConfigError) {
        do {
            try body(&document)
        } catch {
            throw map(error)
        }
    }

    static func map(_ error: any Error) -> McpConfigError {
        switch error as? TOMLError {
        case .malformed(let line, let column, _)?: .unparsableTOML(line: line, column: column)
        case .notFound?: .notFound
        case .conflict?, .unsupportedLayout?: .layoutConflict(path: ["mcp_servers"])
        case .invalidEdit?, nil: .invalidEdit
        }
    }
}
