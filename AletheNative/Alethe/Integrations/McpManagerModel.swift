import AletheDesign
import AletheFoundation
import AletheIntegrations
import Foundation
import Observation

/// What the MCP tab and the MCP manager show (upstream `mcpStore` + `McpManagerModal` state, EXT-1):
/// one scan of every agent for the scope, live health, revealed values and the last change's undo.
/// Every read and write runs in `McpStore` off the main thread; a revealed value lives only here, is
/// never logged, and is dropped on a scope change or when the manager closes.
@MainActor @Observable
final class McpManagerModel {
    /// One revealed env value or header, exactly: two servers of one agent can share a key name.
    struct RevealKey: Hashable {
        let agent: McpAgent
        let source: URL
        let server: String
        let key: String
        let header: Bool
    }

    let store: McpStore
    let registry: McpRegistry
    private let health: McpHealthChecker
    /// Health runs the agents' own CLIs, which read the real home: off when a test home is set.
    let healthAvailable: Bool

    private(set) var scope: McpScope
    private(set) var repository: URL?
    private(set) var snapshots: [McpAgentSnapshot]?
    private(set) var groups: [McpServerGroup] = []
    private(set) var loading = false
    private(set) var busy = false
    private(set) var error: String? { didSet { if error != oldValue { AppLog.shown(error, .integrations) } } }
    /// Outcome of the last change.
    private(set) var note: String?
    /// The last change that can be taken back, by its description.
    private(set) var undoLabel: String?
    private(set) var healthByAgent: [McpAgent: [McpHealth]] = [:]
    private(set) var healthErrors: [McpAgent: McpHealthError] = [:]
    private(set) var checking: Set<McpAgent> = []
    private(set) var revealed: [RevealKey: String] = [:]
    /// Persists the scope switch (`mcpDefaultScope`).
    @ObservationIgnored var onScopeChange: ((McpScope) -> Void)?

    @ObservationIgnored private var undoAction: (() async throws -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var healthTasks: [McpAgent: Task<Void, Never>] = [:]
    @ObservationIgnored private var checkedOnce = false

    init(store: McpStore, registry: McpRegistry, health: McpHealthChecker = McpHealthChecker(),
         healthAvailable: Bool, scope: McpScope) {
        self.store = store
        self.registry = registry
        self.health = health
        self.healthAvailable = healthAvailable
        self.scope = scope
    }

    /// Project scope needs a project; without one the global configs show.
    var effectiveScope: McpScope { repository == nil ? .global : scope }

    /// Agents that can take a new server in this scope.
    var writableAgents: [McpAgent] { (snapshots ?? []).filter(\.isWritable).map(\.agent) }

    /// Agents whose config the scan could not use, and why.
    var issues: [(agent: McpAgent, issue: McpSnapshotIssue)] {
        (snapshots ?? []).compactMap { snapshot in snapshot.issue.map { (snapshot.agent, $0) } }
    }

    func group(named name: String) -> McpServerGroup? { groups.first { $0.name == name } }

    func snapshot(_ agent: McpAgent) -> McpAgentSnapshot? { snapshots?.first { $0.agent == agent } }

    // MARK: Scope and scan

    /// The selected project's folder; a change rescans.
    func setRepository(_ folder: String?) {
        let url = folder.flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        guard url != repository || snapshots == nil else { return }
        if url != repository { revealed = [:] }
        repository = url
        Task { await refresh() }
    }

    func setScope(_ next: McpScope) {
        guard next != scope else { return }
        scope = next
        revealed = [:]
        onScopeChange?(next)
        Task { await refresh() }
    }

    func refresh() async {
        loadTask?.cancel()
        let store = store, scope = effectiveScope, repository = repository
        loading = true
        let task = Task {
            do {
                let snapshots = try await store.scan(scope: scope, repository: repository)
                try Task.checkCancellation()
                self.snapshots = snapshots
                groups = McpStore.groups(snapshots)
                error = nil
            } catch is CancellationError {
                return
            } catch {
                snapshots = snapshots ?? []
                self.error = Self.describe(error)
            }
            loading = false
        }
        loadTask = task
        await task.value
    }

    /// Stops pending work and forgets revealed values (the manager closed).
    func close() {
        revealed = [:]
    }

    func cancel() {
        loadTask?.cancel()
        healthTasks.values.forEach { $0.cancel() }
        healthTasks = [:]
        checking = []
        loading = false
    }

    // MARK: Health

    var healthAgents: [McpAgent] { McpAgent.allCases.filter { McpHealthParser.cli(for: $0) != nil } }

    /// The status `agent`'s CLI reported for `name`; nil before a check.
    func status(of name: String, on agent: McpAgent) -> McpHealthStatus? {
        guard let reported = healthByAgent[agent] else { return nil }
        return reported.first { $0.name == name }?.status ?? .unknown
    }

    /// The worst reported status of a server across the agents checked: what the panel row shows.
    func status(of group: McpServerGroup) -> McpHealthStatus? {
        let statuses = group.agents.compactMap { agent in healthByAgent[agent]?.first { $0.name == group.name }?.status }
        guard !statuses.isEmpty else { return nil }
        for status in [McpHealthStatus.failed, .needsAuth, .disabled, .unknown] where statuses.contains(status) {
            return status
        }
        return .connected
    }

    /// Checks every agent with a CLI once per launch (the tab opening), then on request.
    func checkHealthOnce() {
        guard healthAvailable, !checkedOnce else { return }
        checkedOnce = true
        checkAllHealth()
    }

    func checkAllHealth() {
        let present = Set(groups.flatMap(\.agents))
        healthAgents.filter(present.contains).forEach(checkHealth)
    }

    func checkHealth(_ agent: McpAgent) {
        guard healthAvailable, !checking.contains(agent) else { return }
        checking.insert(agent)
        let health = health
        healthTasks[agent] = Task {
            do {
                healthByAgent[agent] = try await health.check(agent)
                healthErrors[agent] = nil
            } catch {
                if let failure = error as? McpHealthError, failure != .cancelled { healthErrors[agent] = failure }
            }
            checking.remove(agent)
            healthTasks[agent] = nil
        }
    }

    // MARK: Changes

    /// Switches a server on or off in its own file; applies at once with undo.
    func toggle(_ record: McpServerRecord) async {
        let enabled = !record.server.enabled
        let name = record.server.name
        let label = format(enabled ? "mcp.note.enabled" : "mcp.note.disabled", name, record.agent.label)
        await change(label: label) { store, repository in
            _ = try await store.mutate(.setEnabled(name: name, enabled: enabled), agent: record.agent, scope: record.scope,
                                       repository: repository, sourceKind: record.sourceKind)
            return { [store] in
                _ = try await store.mutate(.setEnabled(name: name, enabled: !enabled), agent: record.agent,
                                           scope: record.scope, repository: repository, sourceKind: record.sourceKind)
            }
        }
    }

    /// Removes the server from each record's file. Destructive: the view asked once; each file was
    /// backed up first, so Backups can restore it.
    func remove(_ records: [McpServerRecord]) async {
        guard let name = records.first?.server.name else { return }
        let label = format("mcp.note.removed", name, Self.labels(records.map(\.agent)))
        await change(label: label, undoable: false) { store, repository in
            for record in records {
                _ = try await store.mutate(.remove(name: record.server.name), agent: record.agent, scope: record.scope,
                                           repository: repository, sourceKind: record.sourceKind)
            }
            return nil
        }
    }

    /// Replaces one record's server with the edited form; undo writes the previous one back.
    func save(_ draft: McpServerDraft, over record: McpServerRecord) async throws(McpStoreError) {
        let server = try draft.server()
        let previous = record.server
        await change(label: format("mcp.note.saved", server.name, record.agent.label)) { store, repository in
            _ = try await store.mutate(.upsert(server), agent: record.agent, scope: record.scope, repository: repository,
                                       sourceKind: record.sourceKind)
            return { [store] in
                _ = try await store.mutate(.upsert(previous), agent: record.agent, scope: record.scope,
                                           repository: repository, sourceKind: record.sourceKind)
            }
        }
    }

    /// Writes a new server to each target (agents that already have one by that name are skipped,
    /// never overwritten); undo removes it from where it was written.
    func add(_ draft: McpServerDraft, to targets: [McpAgent]) async throws(McpStoreError) {
        let server = try draft.server()
        let existing = Set(group(named: server.name)?.agents ?? [])
        let scope = effectiveScope
        busy = true
        error = nil
        note = nil
        var written: [McpAgent] = []
        var failures: [String] = []
        for agent in targets where !existing.contains(agent) {
            do {
                _ = try await store.mutate(.upsert(server), agent: agent, scope: scope, repository: repository)
                written.append(agent)
            } catch {
                failures.append("\(agent.label): \(Self.describe(error))")
            }
        }
        let skipped = targets.filter(existing.contains)
        var parts: [String] = []
        if !written.isEmpty { parts.append(format("mcp.note.added", server.name, Self.labels(written))) }
        if !skipped.isEmpty { parts.append(format("mcp.note.skipped", Self.labels(skipped))) }
        note = parts.isEmpty ? nil : parts.joined(separator: " ")
        if !failures.isEmpty { error = format("mcp.error.writeFailed", failures.joined(separator: " · ")) }
        if written.isEmpty {
            clearUndo()
        } else {
            let store = store, repository = repository, name = server.name
            setUndo(format("mcp.undo.add", server.name)) {
                for agent in written {
                    _ = try await store.mutate(.remove(name: name), agent: agent, scope: scope, repository: repository)
                }
            }
        }
        await refresh()
        busy = false
    }

    /// Copies a server to agents that lack it (never overwriting), reporting each target.
    func sync(_ group: McpServerGroup, to targets: [McpAgent]) async {
        guard let from = group.records.first?.agent, !targets.isEmpty else { return }
        busy = true
        error = nil
        note = nil
        do {
            let outcomes = try await store.sync(name: group.name, from: from, to: targets, scope: effectiveScope,
                                                repository: repository)
            let written = outcomes.filter { if case .written = $0.status { true } else { false } }.map(\.agent)
            let skipped = outcomes.filter { $0.status == .skipped }.map(\.agent)
            var parts: [String] = []
            if !written.isEmpty { parts.append(format("mcp.note.synced", group.name, Self.labels(written))) }
            if !skipped.isEmpty { parts.append(format("mcp.note.skipped", Self.labels(skipped))) }
            var problems: [String] = []
            for outcome in outcomes {
                switch outcome.status {
                case .blocked(let fields):
                    problems.append(format("mcp.sync.blocked", outcome.agent.label, fields.map(\.field).joined(separator: ", ")))
                case .failed(let failure):
                    problems.append("\(outcome.agent.label): \(Self.describe(failure))")
                case .written, .skipped:
                    break
                }
            }
            note = parts.isEmpty ? nil : parts.joined(separator: " ")
            error = problems.isEmpty ? nil : problems.joined(separator: " · ")
            if written.isEmpty {
                clearUndo()
            } else {
                let store = store, repository = repository, scope = effectiveScope, name = group.name
                setUndo(format("mcp.undo.sync", group.name)) {
                    for agent in written {
                        _ = try await store.mutate(.remove(name: name), agent: agent, scope: scope, repository: repository)
                    }
                }
            }
        } catch {
            self.error = Self.describe(error)
        }
        await refresh()
        busy = false
    }

    func performUndo() async {
        guard let action = undoAction else { return }
        let label = undoLabel
        clearUndo()
        busy = true
        do {
            try await action()
            note = label.map { format("mcp.note.undone", $0) }
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        await refresh()
        busy = false
    }

    /// Runs one write (or several), then rescans; `body` returns the undo when there is one.
    private func change(label: String, undoable: Bool = true,
                        _ body: (McpStore, URL?) async throws -> (() async throws -> Void)?) async {
        busy = true
        error = nil
        note = nil
        do {
            let undo = try await body(store, repository)
            note = label
            if undoable, let undo { setUndo(label, undo) } else { clearUndo() }
        } catch {
            self.error = Self.describe(error)
        }
        await refresh()
        busy = false
    }

    private func setUndo(_ label: String, _ action: @escaping () async throws -> Void) {
        undoLabel = label
        undoAction = action
    }

    private func clearUndo() {
        undoLabel = nil
        undoAction = nil
    }

    // MARK: Reveal

    func key(_ record: McpServerRecord, _ key: String, header: Bool) -> RevealKey {
        RevealKey(agent: record.agent, source: record.sourceURL, server: record.server.name, key: key, header: header)
    }

    /// Reads one stored value on request; it stays until hidden, a scope change or the manager closing.
    func reveal(_ record: McpServerRecord, key: String, header: Bool) async {
        do {
            let value = try await store.reveal(agent: record.agent, scope: record.scope, repository: repository,
                                               name: record.server.name, key: key, header: header)
            revealed[self.key(record, key, header: header)] = value
        } catch {
            self.error = Self.describe(error)
        }
    }

    func hide(_ key: RevealKey) {
        revealed[key] = nil
    }

    // MARK: Backups

    func backups(for record: McpServerRecord) async -> [ConfigBackup] {
        guard let source = store.source(of: record, repository: repository) else { return [] }
        let store = store
        return await Task.detached { store.backups(agent: record.agent, source: source) }.value
    }

    /// Puts a backup back over the record's file. Destructive: the view asked once. The current
    /// contents are backed up first.
    func restore(_ backup: ConfigBackup, for record: McpServerRecord) async {
        guard let source = store.source(of: record, repository: repository) else { return }
        let label = format("mcp.note.restored", record.sourceURL.lastPathComponent,
                           backup.createdAt.formatted(date: .abbreviated, time: .standard))
        await change(label: label, undoable: false) { store, _ in
            _ = try await store.restore(backup, agent: record.agent, source: source)
            return nil
        }
    }

    // MARK: Text

    static func labels(_ agents: [McpAgent]) -> String {
        agents.map(\.label).joined(separator: ", ")
    }

    /// Codes and field names only: a store error never carries a value from the file.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? McpStoreError else {
            return error is CancellationError ? String(localized: "mcp.error.cancelled") : error.localizedDescription
        }
        switch error {
        case .unsupportedScope: return String(localized: "mcp.error.unsupportedScope")
        case .notFound: return String(localized: "mcp.error.notFound")
        case .invalidName: return String(localized: "mcp.error.invalidName")
        case .invalidCommand: return String(localized: "mcp.error.invalidCommand")
        case .invalidURL: return String(localized: "mcp.error.invalidURL")
        case .unsupportedFields(let fields):
            return format("mcp.error.unsupportedFields", fields.map(\.field).joined(separator: ", "))
        case .selfCheckFailed: return String(localized: "mcp.error.selfCheck")
        case .backupMismatch: return String(localized: "mcp.error.backupMismatch")
        case .cancelled: return String(localized: "mcp.error.cancelled")
        case .config(.jsoncUnsupported): return String(localized: "mcp.error.jsonc")
        case .config(.unsupportedDisable): return String(localized: "mcp.error.unsupportedDisable")
        case .config(let config): return format("mcp.error.config", config.description)
        case .file(.changedSinceRead): return String(localized: "mcp.error.changed")
        case .file: return format("mcp.error.file", error.description)
        }
    }
}

extension McpAgent {
    /// Product names stay as they are.
    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        }
    }

    var colorToken: ThemeToken {
        switch self {
        case .claude: .agentClaude
        case .codex: .agentCodex
        case .cursor: .agentCursor
        case .opencode: .agentOpencode
        case .antigravity: .agentAntigravity
        }
    }
}
