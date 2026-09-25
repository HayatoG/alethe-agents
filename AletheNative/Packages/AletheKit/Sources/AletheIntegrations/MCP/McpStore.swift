import Foundation
import Synchronization

// Port of upstream `mcp_store.rs`: scans every agent's MCP config with an mtime cache, and upserts,
// removes, enables, syncs and reveals servers in the right file. Every write goes through
// `ConfigFileWriter` (re-read, backup into the profile, atomic).

/// One config file an agent reads for a scope (upstream `McpConfigPath`).
public struct McpConfigPath: Hashable, Sendable {
    public let agent: McpAgent
    public let scope: McpScope
    public let kind: McpSourceKind
    public let url: URL
    public let exists: Bool
}

/// Store errors carry codes and field names, never a value from the file.
public enum McpStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The agent has no config for this scope (Antigravity projects), or not of the requested kind.
    case unsupportedScope
    case notFound
    case invalidName
    case invalidCommand
    case invalidURL
    /// The target agent cannot express these fields; nothing was written.
    case unsupportedFields([McpUnsupportedField])
    /// The edited file would have changed servers other than the target; nothing was written.
    case selfCheckFailed
    /// The backup belongs to another agent or file.
    case backupMismatch
    case cancelled
    case config(McpConfigError)
    case file(ConfigFileError)

    public var description: String {
        switch self {
        case .unsupportedScope: "unsupported_scope"
        case .notFound: "not_found"
        case .invalidName: "invalid_name"
        case .invalidCommand: "invalid_command"
        case .invalidURL: "invalid_url"
        case .unsupportedFields(let fields): "unsupported_fields:" + fields.map(\.field).joined(separator: ",")
        case .selfCheckFailed: "self_check_failed"
        case .backupMismatch: "backup_mismatch"
        case .cancelled: "cancelled"
        case .config(let error): error.description
        case .file(.changedSinceRead): "changed_since_read"
        case .file(.unreadable): "unreadable"
        case .file(.backupFailed): "backup_failed"
        case .file(.writeFailed): "write_failed"
        }
    }
}

public enum McpMutation: Hashable, Sendable {
    case upsert(McpServer)
    case remove(name: String)
    case setEnabled(name: String, enabled: Bool)

    public var target: String {
        switch self {
        case .upsert(let server): server.name
        case .remove(let name), .setEnabled(let name, _): name
        }
    }

    var creates: Bool {
        if case .upsert = self { return true }
        return false
    }

    /// Removing a server drops its config, env values included: the UI asks once before applying it.
    /// Everything else applies at once with undo.
    public var needsConfirmation: Bool {
        if case .remove = self { return true }
        return false
    }
}

public enum McpWriteWarning: Hashable, Sendable {
    /// Antigravity: the server came from a plugin import that may write it back.
    case managedByImport(String)
}

public struct McpWriteReport: Equatable, Sendable {
    public let url: URL
    public let kind: McpSourceKind
    /// The previous contents; nil when the file was created.
    public let backup: ConfigBackup?
    public let changed: [String]
    public var warnings: [McpWriteWarning]
}

public struct McpSyncOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case written(URL)
        /// The agent already has a server with that name and overwrite was off.
        case skipped
        /// Fields the agent cannot express; nothing was written.
        case blocked([McpUnsupportedField])
        case failed(McpStoreError)
    }

    public let agent: McpAgent
    public let status: Status
}

/// Servers with the same name across agents (upstream `groupServersByName`, `lib/mcp.ts`).
public struct McpServerGroup: Hashable, Sendable {
    public let name: String
    public let records: [McpServerRecord]
    public let agents: [McpAgent]
    /// Readable agents that lack the server: what Sync All fills.
    public let missingAgents: [McpAgent]
    public let hasDisabled: Bool
}

public struct McpGroupSyncResult: Equatable, Sendable {
    public let name: String
    public let result: Result<[McpSyncOutcome], McpStoreError>
}

extension McpAgentSnapshot {
    /// Only an agent whose every source parsed can be said to miss a server: with an unreadable file
    /// it cannot be told, and with no source the question does not apply.
    public var isReadable: Bool {
        !sources.isEmpty && sources.allSatisfy { $0.parseError == nil }
    }
}

/// Every method ending in `Now` does file I/O synchronously; the async forms run it off the main
/// thread and inherit the caller's cancellation. Revealed values are returned, never logged.
public final class McpStore: Sendable {
    public let home: McpHome
    public let writer: ConfigFileWriter

    private struct CacheKey: Hashable {
        let agent: McpAgent
        let kind: McpSourceKind
        let path: String
        let projectKey: String?
    }

    private struct CacheEntry {
        let modificationDate: Date?
        let size: Int64
        let servers: [McpServer]
    }

    private let cache = Mutex<[CacheKey: CacheEntry]>([:])

    public init(home: McpHome = .current(), writer: ConfigFileWriter) {
        self.home = home
        self.writer = writer
    }

    public static var capabilities: [McpCapability] { McpAgent.allCases.map(\.capability) }

    func sources(_ agent: McpAgent, _ scope: McpScope, _ repository: URL?) -> [McpSource] {
        McpAdapters.adapter(for: agent).configSources(scope: scope, repository: repository, home: home)
    }

    // MARK: Input parsing (upstream `requested_agents`, `repo_path`)

    /// Unknown names are dropped; nil or nothing known means every agent.
    public static func requestedAgents(_ raw: [String]?) -> [McpAgent] {
        let picked = (raw ?? []).compactMap(McpAgent.init(parsing:))
        return picked.isEmpty ? McpAgent.allCases : picked
    }

    public static func repositoryURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return URL(filePath: trimmed, directoryHint: .isDirectory)
    }

    /// Upstream `to_server`: trims the name, command and URL, drops blank env and header keys, and
    /// refuses a name no config can hold as a key.
    public static func validated(_ server: McpServer) throws(McpStoreError) -> McpServer {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: { "/\\\"\n".contains($0) }) else { throw .invalidName }
        let transport: McpTransport
        switch server.transport {
        case .stdio(let command, let arguments, let cwd):
            let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw .invalidCommand }
            transport = .stdio(command: command, arguments: arguments, cwd: cwd)
        case .http(let url, let headers):
            let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { throw .invalidURL }
            transport = .http(url: url, headers: cleaned(headers))
        case .sse(let url, let headers):
            let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { throw .invalidURL }
            transport = .sse(url: url, headers: cleaned(headers))
        }
        var out = server
        out.name = name
        out.transport = transport
        out.env = cleaned(server.env)
        return out
    }

    private static func cleaned(_ map: McpEnvMap) -> McpEnvMap {
        var out: McpEnvMap = [:]
        for (key, entry) in map {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { out[key] = entry }
        }
        return out
    }

    // MARK: Scan

    public func scan(scope: McpScope, repository: URL?, agents: [McpAgent] = McpAgent.allCases) async throws -> [McpAgentSnapshot] {
        try await Self.offMain { try self.scanNow(scope: scope, repository: repository, agents: agents) }
    }

    /// One snapshot per agent (all when `agents` is empty), in the order given.
    public func scanNow(scope: McpScope, repository: URL?, agents: [McpAgent] = McpAgent.allCases) throws -> [McpAgentSnapshot] {
        let picked = agents.isEmpty ? McpAgent.allCases : agents
        let imports = picked.contains(.antigravity) ? antigravityImports() : []
        return try picked.map { agent in
            try Task.checkCancellation()
            return scanAgent(agent, scope: scope, repository: repository, imports: imports)
        }
    }

    func scanAgent(_ agent: McpAgent, scope: McpScope, repository: URL?, imports: [String]) -> McpAgentSnapshot {
        var snapshot = McpAgentSnapshot(agent: agent, scope: scope)
        for source in sources(agent, scope, repository) {
            guard let stat = Self.stat(source.url) else {
                snapshot.sources.append(McpSourceState(kind: source.kind, url: source.url, exists: false,
                                                       writable: Self.isWritable(source.url)))
                continue
            }
            var state = McpSourceState(kind: source.kind, url: source.url, exists: true,
                                       writable: FileManager.default.isWritableFile(atPath: source.url.path(percentEncoded: false)),
                                       modificationDate: stat.modificationDate)
            do {
                for server in try readServers(agent, source, stat) {
                    let owner = agent == .antigravity
                        ? AntigravityMcpAdapter.importOwner(of: server.name, imports: imports) : nil
                    snapshot.servers.append(McpServerRecord(server: server, agent: agent, scope: scope,
                                                            sourceKind: source.kind, sourceURL: source.url,
                                                            managedByImport: owner))
                }
            } catch {
                state.parseError = error
                state.writable = false
            }
            snapshot.sources.append(state)
        }
        return snapshot
    }

    /// Parsed servers, reused while the file's modification date and size are unchanged.
    private func readServers(_ agent: McpAgent, _ source: McpSource, _ stat: FileStat) throws(McpConfigError) -> [McpServer] {
        let key = Self.cacheKey(agent, source)
        if let entry = cache.withLock({ $0[key] }), entry.modificationDate == stat.modificationDate, entry.size == stat.size {
            return entry.servers
        }
        guard let data = try? Data(contentsOf: source.url) else { throw .unreadable }
        let servers = try McpAdapters.adapter(for: agent).parse(String(decoding: data, as: UTF8.self), source: source)
        cache.withLock { $0[key] = CacheEntry(modificationDate: stat.modificationDate, size: stat.size, servers: servers) }
        return servers
    }

    private static func cacheKey(_ agent: McpAgent, _ source: McpSource) -> CacheKey {
        CacheKey(agent: agent, kind: source.kind, path: source.url.standardizedFileURL.path(percentEncoded: false),
                 projectKey: source.projectKey)
    }

    private func invalidate(_ agent: McpAgent, _ source: McpSource) {
        let key = Self.cacheKey(agent, source)
        _ = cache.withLock { $0.removeValue(forKey: key) }
    }

    private struct FileStat {
        let modificationDate: Date?
        let size: Int64
    }

    /// Follows symlinks, like upstream's `fs::metadata`.
    private static func stat(_ url: URL) -> FileStat? {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStat(modificationDate: attributes[.modificationDate] as? Date,
                        size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// A missing file is writable when its folder exists (upstream `is_writable`).
    static func isWritable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path) { return fileManager.isWritableFile(atPath: path) }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Antigravity names the plugin imports it applied, not the servers they added.
    func antigravityImports() -> [String] {
        guard let data = try? Data(contentsOf: AntigravityMcpAdapter.importManifestURL(home: home)) else { return [] }
        return AntigravityMcpAdapter.importNames(manifest: String(decoding: data, as: UTF8.self))
    }

    // MARK: Paths

    public func configPaths(scope: McpScope, repository: URL?) async throws -> [McpConfigPath] {
        try await Self.offMain { self.configPathsNow(scope: scope, repository: repository) }
    }

    public func configPathsNow(scope: McpScope, repository: URL?) -> [McpConfigPath] {
        McpAgent.allCases.flatMap { agent in
            sources(agent, scope, repository).map { source in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: source.url.path(percentEncoded: false), isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                return McpConfigPath(agent: agent, scope: scope, kind: source.kind, url: source.url, exists: exists)
            }
        }
    }

    // MARK: Source picking

    /// Upstream `pick_source`: an existing server is edited where it lives; a new one goes to the
    /// agent's first source, which for Claude at project scope is the `local` entry in
    /// `~/.claude.json` (where `claude mcp add` writes). `kind` forces one source.
    func pickSource(_ agent: McpAgent, scope: McpScope, repository: URL?, name: String,
                    kind: McpSourceKind?, creating: Bool) throws(McpStoreError) -> McpSource {
        let sources = sources(agent, scope, repository)
        guard let first = sources.first else { throw .unsupportedScope }
        if let kind {
            guard let source = sources.first(where: { $0.kind == kind }) else { throw .unsupportedScope }
            return source
        }
        for source in sources where Self.servers(agent, source)?.contains(where: { $0.name == name }) == true {
            return source
        }
        guard creating else { throw .notFound }
        return first
    }

    /// The source's servers, or nil when it is missing or unparsable.
    private static func servers(_ agent: McpAgent, _ source: McpSource) -> [McpServer]? {
        guard let data = try? Data(contentsOf: source.url) else { return nil }
        return try? McpAdapters.adapter(for: agent).parse(String(decoding: data, as: UTF8.self), source: source)
    }

    // MARK: Mutations

    public func mutate(_ mutation: McpMutation, agent: McpAgent, scope: McpScope, repository: URL?,
                       sourceKind: McpSourceKind? = nil) async throws -> McpWriteReport {
        try await Self.offMain {
            try self.mutateNow(mutation, agent: agent, scope: scope, repository: repository, sourceKind: sourceKind)
        }
    }

    /// Upserts (validated first), removes or switches a server in the file it belongs to.
    public func mutateNow(_ mutation: McpMutation, agent: McpAgent, scope: McpScope, repository: URL?,
                          sourceKind: McpSourceKind? = nil) throws(McpStoreError) -> McpWriteReport {
        var mutation = mutation
        if case .upsert(let server) = mutation { mutation = .upsert(try Self.validated(server)) }
        let source = try pickSource(agent, scope: scope, repository: repository, name: mutation.target,
                                    kind: sourceKind, creating: mutation.creates)
        var warnings: [McpWriteWarning] = []
        if agent == .antigravity,
           let owner = AntigravityMcpAdapter.importOwner(of: mutation.target, imports: antigravityImports()) {
            warnings.append(.managedByImport(owner))
        }
        var report = try apply(mutation, agent: agent, to: source)
        report.warnings = warnings
        return report
    }

    /// Upstream `apply_to_source`: parse, guard, generate, re-validate, back up, write atomically.
    func apply(_ mutation: McpMutation, agent: McpAgent, to source: McpSource) throws(McpStoreError) -> McpWriteReport {
        if source.isJSONC { throw .config(.jsoncUnsupported) }
        let snapshot: ConfigFileSnapshot
        do {
            snapshot = try writer.read(source.url)
        } catch {
            throw .file(error)
        }
        if !snapshot.exists && !mutation.creates { throw .notFound }

        let adapter = McpAdapters.adapter(for: agent)
        let raw = snapshot.text
        let target = mutation.target
        let expectedOthers: [String]
        do {
            expectedOthers = Self.otherNames(try adapter.parse(raw, source: source), target)
        } catch {
            throw .config(error)
        }

        if case .upsert(let server) = mutation {
            let blocked = server.unsupportedFields(for: agent)
            if !blocked.isEmpty { throw .unsupportedFields(blocked) }
        }

        let next: String
        do {
            switch mutation {
            case .upsert(let server): next = try adapter.upsert(raw, source: source, server: server)
            case .remove(let name): next = try adapter.remove(raw, source: source, name: name)
            case .setEnabled(let name, let enabled): next = try adapter.setEnabled(raw, source: source, name: name, enabled: enabled)
            }
        } catch {
            throw .config(error)
        }

        guard let after = try? adapter.parse(next, source: source), Self.otherNames(after, target) == expectedOthers else {
            throw .selfCheckFailed
        }

        let written: ConfigWriteReport
        do {
            written = try writer.write(next, over: snapshot, backupSlot: backupSlot(agent: agent, source: source))
        } catch {
            throw .file(error)
        }
        invalidate(agent, source)
        return McpWriteReport(url: source.url, kind: source.kind, backup: written.backup, changed: [target], warnings: [])
    }

    private static func otherNames(_ servers: [McpServer], _ target: String) -> [String] {
        servers.map(\.name).filter { $0 != target }.sorted()
    }

    // MARK: Read one server

    /// The first source of the scope holding `name`.
    func readServer(_ agent: McpAgent, scope: McpScope, repository: URL?, name: String) throws(McpStoreError) -> McpServer {
        let sources = sources(agent, scope, repository)
        guard !sources.isEmpty else { throw .unsupportedScope }
        for source in sources {
            if let server = Self.servers(agent, source)?.first(where: { $0.name == name }) { return server }
        }
        throw .notFound
    }

    // MARK: Sync

    public func sync(name: String, from: McpAgent, to targets: [McpAgent], scope: McpScope, repository: URL?,
                     overwrite: Bool = false) async throws -> [McpSyncOutcome] {
        try await Self.offMain {
            try self.syncNow(name: name, from: from, to: targets, scope: scope, repository: repository, overwrite: overwrite)
        }
    }

    /// Copies one server to other agents inside the store, so a stored secret never travels through
    /// the UI. `overwrite` replaces a server the target already has: the UI asks once before passing it.
    /// Cancelling stops before the next target; the rest report `.failed(.cancelled)`.
    public func syncNow(name: String, from: McpAgent, to targets: [McpAgent], scope: McpScope, repository: URL?,
                        overwrite: Bool = false) throws(McpStoreError) -> [McpSyncOutcome] {
        let server = try readServer(from, scope: scope, repository: repository, name: name)
        var seen = Set<McpAgent>()
        return targets.filter { $0 != from && seen.insert($0).inserted }.map { agent in
            McpSyncOutcome(agent: agent, status: syncOne(server, to: agent, scope: scope, repository: repository, overwrite: overwrite))
        }
    }

    private func syncOne(_ server: McpServer, to agent: McpAgent, scope: McpScope, repository: URL?,
                         overwrite: Bool) -> McpSyncOutcome.Status {
        if Task.isCancelled { return .failed(.cancelled) }
        let unsupported = server.unsupportedFields(for: agent)
        if !unsupported.isEmpty { return .blocked(unsupported) }
        if !overwrite, (try? readServer(agent, scope: scope, repository: repository, name: server.name)) != nil {
            return .skipped
        }
        do {
            let source = try pickSource(agent, scope: scope, repository: repository, name: server.name, kind: nil, creating: true)
            return .written(try apply(.upsert(server), agent: agent, to: source).url)
        } catch {
            return .failed(error)
        }
    }

    public static func groups(_ snapshots: [McpAgentSnapshot]) -> [McpServerGroup] {
        let readable = Set(snapshots.filter(\.isReadable).map(\.agent))
        var order: [String] = []
        var byName: [String: [McpServerRecord]] = [:]
        for record in snapshots.flatMap(\.servers) {
            if byName[record.server.name] == nil { order.append(record.server.name) }
            byName[record.server.name, default: []].append(record)
        }
        return order.map { name in
            let records = byName[name] ?? []
            let present = Set(records.map(\.agent))
            return McpServerGroup(
                name: name,
                records: records,
                agents: McpAgent.allCases.filter(present.contains),
                missingAgents: McpAgent.allCases.filter { readable.contains($0) && !present.contains($0) },
                hasDisabled: records.contains { !$0.server.enabled }
            )
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    public func syncAll(_ groups: [McpServerGroup], scope: McpScope, repository: URL?) async throws -> [McpGroupSyncResult] {
        try await Self.offMain { self.syncAllNow(groups, scope: scope, repository: repository) }
    }

    /// Onboarding's Sync All (upstream `McpStep`): each group's gaps filled from its first record,
    /// never overwriting.
    public func syncAllNow(_ groups: [McpServerGroup], scope: McpScope, repository: URL?) -> [McpGroupSyncResult] {
        groups.filter { !$0.missingAgents.isEmpty }.compactMap { group in
            guard let from = group.records.first?.agent else { return nil }
            let result = Result { () throws(McpStoreError) -> [McpSyncOutcome] in
                try syncNow(name: group.name, from: from, to: group.missingAgents, scope: scope, repository: repository)
            }
            return McpGroupSyncResult(name: group.name, result: result)
        }
    }

    // MARK: Reveal

    public func reveal(agent: McpAgent, scope: McpScope, repository: URL?, name: String, key: String,
                       header: Bool = false) async throws -> String {
        try await Self.offMain {
            try self.revealNow(agent: agent, scope: scope, repository: repository, name: name, key: key, header: header)
        }
    }

    /// The only way a stored literal leaves the store, one key per request. Callers never log it.
    public func revealNow(agent: McpAgent, scope: McpScope, repository: URL?, name: String, key: String,
                          header: Bool = false) throws(McpStoreError) -> String {
        let server = try readServer(agent, scope: scope, repository: repository, name: name)
        let map: McpEnvMap
        if header {
            guard let headers = server.transport.headers else { throw .notFound }
            map = headers
        } else {
            map = server.env
        }
        guard let literal = map[key]?.literal else { throw .notFound }
        return literal
    }

    // MARK: Backups

    /// `<agent>-<kind>`; a repository file gets a slot of its own (`<agent>-project_<hash>`) so a
    /// backup of one repository is never offered for another (upstream shares one prefix).
    public func backupSlot(agent: McpAgent, source: McpSource) -> ConfigBackupSlot {
        guard source.kind == .project else { return ConfigBackupSlot(agent: agent.rawValue, kind: source.kind.rawValue) }
        let path = source.url.standardizedFileURL.path(percentEncoded: false)
        return ConfigBackupSlot(agent: agent.rawValue, kind: "project_" + Self.fnv1a(path))
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }

    /// The backups of a source's file, newest first.
    public func backups(agent: McpAgent, source: McpSource) -> [ConfigBackup] {
        writer.backups(in: backupSlot(agent: agent, source: source))
    }

    public func restore(_ backup: ConfigBackup, agent: McpAgent, source: McpSource) async throws -> McpWriteReport {
        try await Self.offMain { try self.restoreNow(backup, agent: agent, source: source) }
    }

    /// Puts a backup back into the source's file, backing up the current contents first so the
    /// restore can itself be undone. Destructive: the UI asks once. A backup the agent cannot parse
    /// is refused rather than leaving a broken config.
    public func restoreNow(_ backup: ConfigBackup, agent: McpAgent, source: McpSource) throws(McpStoreError) -> McpWriteReport {
        guard backup.slot == backupSlot(agent: agent, source: source) else { throw .backupMismatch }
        if source.isJSONC { throw .config(.jsoncUnsupported) }
        guard let data = try? Data(contentsOf: backup.url) else { throw .file(.unreadable(backup.url, "unreadable")) }
        do {
            _ = try McpAdapters.adapter(for: agent).parse(String(decoding: data, as: UTF8.self), source: source)
        } catch {
            throw .config(error)
        }
        let written: ConfigWriteReport
        do {
            written = try writer.restore(backup, to: source.url)
        } catch {
            throw .file(error)
        }
        invalidate(agent, source)
        return McpWriteReport(url: source.url, kind: source.kind, backup: written.backup, changed: [], warnings: [])
    }

    // MARK: Off main

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
