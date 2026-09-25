import AletheFoundation
import Foundation

// Port of upstream `mcp_agents.rs`: where each agent keeps its MCP servers and how to read and edit
// that file as text. Adapters are pure text-in, text-out; reading, backups and atomic writes belong to
// the MCP store (P5-21) through `ConfigFileWriter`.

/// Errors carry a position and never a snippet of the file: these configs hold live credentials.
public enum McpConfigError: Error, Hashable, Sendable, CustomStringConvertible {
    case unparsableJSON(line: Int, column: Int)
    case unparsableTOML(line: Int, column: Int)
    case rootNotAnObject
    /// A key on the way to the server holds something other than an object or table; it is never
    /// replaced blindly.
    case layoutConflict(path: [String])
    case notFound
    /// The agent's config has no way to switch a server off (Claude Code, Cursor, Antigravity).
    case unsupportedDisable
    /// `.jsonc` files are read but never written: their comments would be lost.
    case jsoncUnsupported
    /// The edit did not produce the expected document; nothing was changed.
    case invalidEdit

    public var description: String {
        switch self {
        case .unparsableJSON(let line, let column): "unparsable:json line \(line) column \(column)"
        case .unparsableTOML(let line, let column): "unparsable:toml line \(line) column \(column)"
        case .rootNotAnObject: "unparsable:json root is not an object"
        case .layoutConflict(let path): "unparsable:\(path.joined(separator: "."))"
        case .notFound: "not_found"
        case .unsupportedDisable: "unsupported_disable"
        case .jsoncUnsupported: "jsonc_unsupported"
        case .invalidEdit: "invalid_edit"
        }
    }
}

/// One file an agent reads its servers from. `projectKey` selects Claude's `projects.<folder>` entry
/// inside `~/.claude.json` for the `local` source.
public struct McpSource: Hashable, Sendable {
    public var url: URL
    public var kind: McpSourceKind
    public var projectKey: String?

    public init(url: URL, kind: McpSourceKind, projectKey: String? = nil) {
        self.url = url
        self.kind = kind
        self.projectKey = projectKey
    }

    var isJSONC: Bool { url.pathExtension.lowercased() == "jsonc" }
}

/// The home the global configs are looked up in. `ALETHE_MCP_HOME` redirects every global lookup to a
/// scratch copy (upstream's test hook), which also ignores `XDG_CONFIG_HOME`.
public struct McpHome: Hashable, Sendable {
    public var home: URL
    public var xdgConfigHome: URL?

    public init(home: URL, xdgConfigHome: URL? = nil) {
        self.home = home
        self.xdgConfigHome = xdgConfigHome
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> McpHome {
        if let override = environment["ALETHE_MCP_HOME"], !override.isEmpty {
            return McpHome(home: URL(filePath: override, directoryHint: .isDirectory))
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        return McpHome(home: URL(filePath: home, directoryHint: .isDirectory), xdgConfigHome: xdg)
    }

    func path(_ segments: String...) -> URL {
        segments.reduce(home) { $0.appending(path: $1, directoryHint: .notDirectory) }
    }

    /// OpenCode's global config folder: `$XDG_CONFIG_HOME/opencode` or `~/.config/opencode`.
    var opencodeConfigDirectory: URL {
        (xdgConfigHome ?? home.appending(path: ".config", directoryHint: .isDirectory))
            .appending(path: "opencode", directoryHint: .isDirectory)
    }
}

public protocol McpAdapter: Sendable {
    var agent: McpAgent { get }
    /// The files serving `scope`, in the order they are read and preferred for writes.
    func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource]
    /// Servers sorted by name; an empty file or one without servers is an empty list.
    func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer]
    /// Writes `server` under its name, rewriting only the keys this adapter owns.
    func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String
    func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String
    func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String
}

public enum McpAdapters {
    public static func adapter(for agent: McpAgent) -> any McpAdapter {
        switch agent {
        case .claude: ClaudeMcpAdapter()
        case .codex: CodexMcpAdapter()
        case .cursor: CursorMcpAdapter()
        case .opencode: OpenCodeMcpAdapter()
        case .antigravity: AntigravityMcpAdapter()
        }
    }
}

// MARK: - Claude Code

/// Keys the Claude-shaped adapters (Claude Code, Cursor, Antigravity) own on a server entry.
let claudeManagedKeys = ["type", "command", "args", "cwd", "env", "url", "headers", "disabled"]
let openCodeManagedKeys = ["type", "command", "cwd", "environment", "url", "headers", "enabled"]

public struct ClaudeMcpAdapter: McpAdapter {
    public init() {}
    public var agent: McpAgent { .claude }

    /// Global: `~/.claude.json` `mcpServers`. Project: the `local` servers in `~/.claude.json`
    /// `projects.<folder>`, then the shareable `<repo>/.mcp.json`.
    public func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource] {
        let userConfig = home.path(".claude.json")
        switch scope {
        case .global:
            return [McpSource(url: userConfig, kind: .user)]
        case .project:
            guard let repository else { return [] }
            return [
                McpSource(url: userConfig, kind: .local, projectKey: Self.projectKey(for: repository)),
                McpSource(url: repository.appending(path: ".mcp.json", directoryHint: .notDirectory), kind: .project),
            ]
        }
    }

    /// Claude keys `projects` by the folder path with forward slashes.
    public static func projectKey(for repository: URL) -> String {
        projectKey(forPath: repository.path(percentEncoded: false))
    }

    static func projectKey(forPath path: String) -> String {
        var key = path.replacingOccurrences(of: "\\", with: "/")
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }

    public func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        try McpJSON.parseServers(text, rootKey: "mcpServers", source: source)
    }

    public func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        try McpJSON.upsert(text, rootKey: "mcpServers", managedKeys: claudeManagedKeys, opencode: false, source: source, server: server)
    }

    public func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        try McpJSON.remove(text, rootKey: "mcpServers", source: source, name: name)
    }

    public func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String {
        throw .unsupportedDisable
    }
}

// MARK: - Cursor

/// Cursor reads `mcpServers` in the Claude shape from `~/.cursor/mcp.json` and per repository from
/// `<repo>/.cursor/mcp.json`, the file it writes when a server is added from inside the IDE.
public struct CursorMcpAdapter: McpAdapter {
    public init() {}
    public var agent: McpAgent { .cursor }

    public func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource] {
        switch scope {
        case .global:
            return [McpSource(url: home.path(".cursor", "mcp.json"), kind: .user)]
        case .project:
            guard let repository else { return [] }
            return [McpSource(url: repository.appending(path: ".cursor/mcp.json", directoryHint: .notDirectory), kind: .project)]
        }
    }

    public func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        try McpJSON.parseServers(text, rootKey: "mcpServers", source: source)
    }

    public func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        try McpJSON.upsert(text, rootKey: "mcpServers", managedKeys: claudeManagedKeys, opencode: false, source: source, server: server)
    }

    public func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        try McpJSON.remove(text, rootKey: "mcpServers", source: source, name: name)
    }

    public func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String {
        throw .unsupportedDisable
    }
}

// MARK: - Antigravity

/// Antigravity: `~/.gemini/config/mcp_config.json` in the Claude shape, global only.
public struct AntigravityMcpAdapter: McpAdapter {
    public init() {}
    public var agent: McpAgent { .antigravity }

    public func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource] {
        switch scope {
        case .global: [McpSource(url: home.path(".gemini", "config", "mcp_config.json"), kind: .user)]
        case .project: []
        }
    }

    /// The plugin import manifest next to the config.
    public static func importManifestURL(home: McpHome) -> URL {
        home.path(".gemini", "config", "import_manifest.json")
    }

    /// Import names from `import_manifest.json` (`{"imports": [{"name": …}]}`); an unreadable manifest
    /// has none.
    public static func importNames(manifest text: String) -> [String] {
        guard case .object(let root)? = try? OrderedJSON.parse(text),
              let imports = root["imports"]?.arrayValue else { return [] }
        return imports.compactMap { $0.objectValue?["name"]?.stringValue }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The manifest does not name the servers an import added, so one is matched by name prefix
    /// (case-insensitive).
    public static func importOwner(of serverName: String, imports: [String]) -> String? {
        let needle = serverName.lowercased()
        return imports.first { needle.hasPrefix($0.lowercased()) }
    }

    public func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        try McpJSON.parseServers(text, rootKey: "mcpServers", source: source)
    }

    public func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        try McpJSON.upsert(text, rootKey: "mcpServers", managedKeys: claudeManagedKeys, opencode: false, source: source, server: server)
    }

    public func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        try McpJSON.remove(text, rootKey: "mcpServers", source: source, name: name)
    }

    public func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String {
        throw .unsupportedDisable
    }
}

// MARK: - OpenCode

/// OpenCode: `mcp` in `opencode.json` (or `opencode.jsonc` when only that exists) in the global config
/// folder or the repository root. Commands are one array; `{env:NAME}` late-binds a host variable.
public struct OpenCodeMcpAdapter: McpAdapter {
    public init() {}
    public var agent: McpAgent { .opencode }

    public func configSources(scope: McpScope, repository: URL?, home: McpHome) -> [McpSource] {
        let directory: URL
        let kind: McpSourceKind
        switch scope {
        case .global:
            directory = home.opencodeConfigDirectory
            kind = .user
        case .project:
            guard let repository else { return [] }
            directory = repository
            kind = .project
        }
        let json = directory.appending(path: "opencode.json", directoryHint: .notDirectory)
        let jsonc = directory.appending(path: "opencode.jsonc", directoryHint: .notDirectory)
        if !Self.isFile(json) && Self.isFile(jsonc) {
            return [McpSource(url: jsonc, kind: kind)]
        }
        return [McpSource(url: json, kind: kind)]
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    public func parse(_ text: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        guard let root = try McpJSON.root(text, allowComments: source.isJSONC),
              let servers = root["mcp"]?.objectValue else { return [] }
        return servers.compactMap { member in
            member.value.objectValue.map { Self.server(member.key, $0) }
        }.sorted { $0.name < $1.name }
    }

    static func server(_ name: String, _ object: OrderedJSONObject) -> McpServer {
        let transport: McpTransport
        if let url = object["url"]?.stringValue {
            transport = .http(url: url, headers: McpJSON.env(object["headers"], interpolate: true))
        } else {
            let parts = McpJSON.stringArray(object["command"])
            transport = .stdio(command: parts.first ?? "", arguments: Array(parts.dropFirst()), cwd: object["cwd"]?.stringValue)
        }
        return McpServer(
            name: name,
            transport: transport,
            env: McpJSON.env(object["environment"], interpolate: true),
            enabled: object["enabled"]?.boolValue ?? true
        )
    }

    public func upsert(_ text: String, source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        try McpJSON.upsert(text, rootKey: "mcp", managedKeys: openCodeManagedKeys, opencode: true, source: source, server: server)
    }

    public func remove(_ text: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        try McpJSON.remove(text, rootKey: "mcp", source: source, name: name)
    }

    public func setEnabled(_ text: String, source: McpSource, name: String, enabled: Bool) throws(McpConfigError) -> String {
        guard !source.isJSONC else { throw .jsoncUnsupported }
        var editor = try McpJSON.editor(text)
        guard editor.value(at: ["mcp", name])?.objectValue != nil else { throw .notFound }
        do {
            try editor.set(.bool(enabled), at: ["mcp", name, "enabled"])
        } catch {
            throw McpJSON.map(error)
        }
        return editor.rendered()
    }
}

// MARK: - Shared JSON shape

enum McpJSON {
    /// The parsed root object; nil when the file is empty or its root is not an object (read as no
    /// servers, as upstream does).
    static func root(_ text: String, allowComments: Bool) throws(McpConfigError) -> OrderedJSONObject? {
        let source = allowComments ? JSONC.strip(text) : text
        guard !source.allSatisfy(\.isWhitespace) else { return nil }
        do {
            return try OrderedJSON.parse(source).objectValue
        } catch {
            throw .unparsableJSON(line: error.line, column: error.column)
        }
    }

    static func editor(_ text: String) throws(McpConfigError) -> JSONConfigEditor {
        do {
            return try JSONConfigEditor(parsing: text)
        } catch {
            throw map(error)
        }
    }

    static func map(_ error: JSONConfigError) -> McpConfigError {
        switch error {
        case .unparsable(let parse): .unparsableJSON(line: parse.line, column: parse.column)
        case .rootNotAnObject: .rootNotAnObject
        case .notAnObject(let path): .layoutConflict(path: path)
        case .emptyPath: .invalidEdit
        }
    }

    /// Upstream `normalized_project_key`: slashes unified, no trailing slash, case-insensitive.
    static func normalizedProjectKey(_ raw: String) -> String {
        var key = raw.replacingOccurrences(of: "\\", with: "/")
        while key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }

    static func resolveProjectKey(in projects: OrderedJSONObject, wanted: String) -> String? {
        let needle = normalizedProjectKey(wanted)
        return projects.keys.first { normalizedProjectKey($0) == needle }
    }

    /// The key path of the object holding the servers, or nil when a `local` source's project entry
    /// does not exist yet.
    static func containerPath(in root: OrderedJSONObject, rootKey: String, source: McpSource) -> [String]? {
        guard source.kind == .local, let wanted = source.projectKey else { return [rootKey] }
        guard let projects = root["projects"]?.objectValue,
              let key = resolveProjectKey(in: projects, wanted: wanted) else { return nil }
        return ["projects", key, rootKey]
    }

    static func parseServers(_ text: String, rootKey: String, source: McpSource) throws(McpConfigError) -> [McpServer] {
        guard let root = try root(text, allowComments: source.isJSONC),
              let path = containerPath(in: root, rootKey: rootKey, source: source),
              let servers = JSONConfigEditor(root: root).value(at: path)?.objectValue else { return [] }
        return servers.compactMap { member in
            member.value.objectValue.map { claudeShapedServer(member.key, $0) }
        }.sorted { $0.name < $1.name }
    }

    /// Claude, Cursor and Antigravity: env values are literal (`{env:X}` is not interpolated).
    static func claudeShapedServer(_ name: String, _ object: OrderedJSONObject) -> McpServer {
        let declared = object["type"]?.stringValue ?? ""
        let transport: McpTransport
        if let url = object["url"]?.stringValue {
            let headers = env(object["headers"], interpolate: false)
            transport = declared == "sse" ? .sse(url: url, headers: headers) : .http(url: url, headers: headers)
        } else {
            transport = .stdio(
                command: object["command"]?.stringValue ?? "",
                arguments: stringArray(object["args"]),
                cwd: object["cwd"]?.stringValue
            )
        }
        return McpServer(
            name: name,
            transport: transport,
            env: env(object["env"], interpolate: false),
            enabled: !(object["disabled"]?.boolValue ?? false)
        )
    }

    static func stringArray(_ value: OrderedJSON?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    static func env(_ value: OrderedJSON?, interpolate: Bool) -> McpEnvMap {
        guard let object = value?.objectValue else { return [:] }
        var out: McpEnvMap = [:]
        for member in object {
            guard let text = member.value.stringValue else { continue }
            out[member.key] = entry(text, interpolate: interpolate)
        }
        return out
    }

    /// OpenCode late-binds a host variable with `{env:NAME}`; everywhere else the value is literal.
    static func entry(_ raw: String, interpolate: Bool) -> McpEnvEntry {
        if interpolate, raw.hasPrefix("{env:"), raw.hasSuffix("}"), raw.count >= 6 {
            let name = raw.dropFirst(5).dropLast().trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .passthrough(name) }
        }
        return .literal(raw)
    }

    static func envValue(_ entry: McpEnvEntry, interpolate: Bool) -> OrderedJSON? {
        if interpolate, let from = entry.passthroughFrom { return .string("{env:\(from)}") }
        return entry.literal.map(OrderedJSON.string)
    }

    static func envObject(_ env: McpEnvMap, interpolate: Bool) -> OrderedJSON? {
        let members = env.sorted { $0.key < $1.key }.compactMap { key, entry in
            envValue(entry, interpolate: interpolate).map { (key, $0) }
        }
        return members.isEmpty ? nil : .object(OrderedJSONObject(members))
    }

    /// The managed values of an entry in upstream's insertion order.
    static func entryValues(_ server: McpServer, opencode: Bool) -> [(String, OrderedJSON)] {
        var values: [(String, OrderedJSON)] = []
        if let env = envObject(server.env, interpolate: opencode) {
            values.append((opencode ? "environment" : "env", env))
        }
        switch server.transport {
        case .stdio(let command, let arguments, let cwd):
            if opencode {
                values.append(("type", .string("local")))
                values.append(("command", .array(([command] + arguments).map(OrderedJSON.string))))
            } else {
                values.append(("type", .string("stdio")))
                values.append(("command", .string(command)))
                if !arguments.isEmpty { values.append(("args", .array(arguments.map(OrderedJSON.string)))) }
            }
            if let cwd { values.append(("cwd", .string(cwd))) }
        case .http(let url, let headers), .sse(let url, let headers):
            let kind: String
            if opencode {
                kind = "remote"
            } else if case .sse = server.transport {
                kind = "sse"
            } else {
                kind = "http"
            }
            values.append(("type", .string(kind)))
            values.append(("url", .string(url)))
            if let headers = envObject(headers, interpolate: opencode) { values.append(("headers", headers)) }
        }
        if opencode {
            values.append(("enabled", .bool(server.enabled)))
        } else if !server.enabled {
            values.append(("disabled", .bool(true)))
        }
        return values
    }

    /// Rewrites only the keys the adapter owns, so anything the user added to the entry survives.
    static func upsert(_ text: String, rootKey: String, managedKeys: [String], opencode: Bool,
                       source: McpSource, server: McpServer) throws(McpConfigError) -> String {
        guard !source.isJSONC else { throw .jsoncUnsupported }
        var editor = try editor(text)
        let container = containerPath(in: editor.root, rootKey: rootKey, source: source)
            ?? ["projects", ClaudeMcpAdapter.projectKey(forPath: source.projectKey ?? ""), rootKey]
        do {
            try editor.upsertObject(at: container + [server.name], managedKeys: managedKeys,
                                    values: entryValues(server, opencode: opencode))
        } catch {
            throw map(error)
        }
        return editor.rendered()
    }

    static func remove(_ text: String, rootKey: String, source: McpSource, name: String) throws(McpConfigError) -> String {
        guard !source.isJSONC else { throw .jsoncUnsupported }
        var editor = try editor(text)
        guard let container = containerPath(in: editor.root, rootKey: rootKey, source: source),
              editor.value(at: container)?.objectValue?[name] != nil else { throw .notFound }
        do {
            try editor.remove(at: container + [name])
        } catch {
            throw map(error)
        }
        return editor.rendered()
    }
}
