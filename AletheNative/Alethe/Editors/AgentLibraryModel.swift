import AletheFoundation
import AletheIntegrations
import Foundation

/// State of the Agent Library sheet (P5-16): the agents of one scope, the economy toggle and the
/// last change for Undo. Disk work runs off the main thread; every failure lands in `error`.
@MainActor @Observable
final class AgentLibraryModel {
    enum ScopeChoice: String, CaseIterable, Identifiable {
        case project, user
        var id: String { rawValue }
    }

    let projectFolder: URL
    let home: URL
    private let store: AgentLibraryStore

    private(set) var scopeChoice: ScopeChoice = .project
    private(set) var installed: [InstalledAgent] = []
    private(set) var economyOn = false
    private(set) var loading = true
    private(set) var running = false
    private(set) var error: String? { didSet { if error != oldValue { AppLog.shown(error, .integrations) } } }
    /// Outcome of the last action.
    private(set) var note: String?
    /// Claude Code reads `.claude/agents` when a session starts.
    private(set) var restartHint = false
    /// The last change, undoable while its files are untouched.
    private(set) var lastChange: (change: AgentLibraryChange, scope: AgentLibraryScope)?
    /// A library agent whose name is taken by a file Alethe did not write: overwrite asks first.
    var pendingOverwrite: AgentTemplate?
    /// An agent without the Alethe marker the user asked to remove: asks first.
    var pendingForeignRemoval: InstalledAgent?

    @ObservationIgnored private var work: Task<Void, Never>?

    init(projectFolder: URL, home: URL, profileDirectory: URL) {
        self.projectFolder = projectFolder
        self.home = home
        store = AgentLibraryStore(writer: ConfigFileWriter(profileDirectory: profileDirectory))
    }

    var scope: AgentLibraryScope {
        switch scopeChoice {
        case .project: .project(projectFolder)
        case .user: .user(home: home)
        }
    }

    func installed(_ name: String) -> InstalledAgent? {
        installed.first { $0.name == name }
    }

    /// Agents in the folder that are neither library nor economy templates.
    var otherAgents: [InstalledAgent] {
        let known = Set((AgentLibraryCatalog.templates + EconomyAgents.templates).map(\.name))
        return installed.filter { !known.contains($0.name) }
    }

    func select(_ choice: ScopeChoice) {
        guard choice != scopeChoice else { return }
        scopeChoice = choice
        note = nil
        error = nil
        Task { await refresh() }
    }

    func refresh() async {
        let store = store
        let scope = scope
        let (agents, economy) = await Task.detached {
            (store.installed(in: scope), store.economyEnabled(in: scope))
        }.value
        guard scope == self.scope else { return }
        installed = agents
        economyOn = economy
        loading = false
    }

    func install(_ template: AgentTemplate, overwriteForeign: Bool = false) {
        perform(done: String(format: String(localized: "agentLibrary.installed.note"), template.name)) { store, scope in
            try store.install(template, in: scope, overwriteForeign: overwriteForeign)
        } onError: { error in
            guard case .conflict = error else { return false }
            self.pendingOverwrite = template
            return true
        }
    }

    /// Alethe's files go at once (with Undo); any other file asks first.
    func remove(_ agent: InstalledAgent, force: Bool = false) {
        guard agent.fromAlethe || force else {
            pendingForeignRemoval = agent
            return
        }
        perform(done: String(format: String(localized: "agentLibrary.removed.note"), agent.name)) { store, scope in
            try store.uninstall(agent.name, in: scope, force: force)
        } onError: { error in
            guard case .notAlethe = error else { return false }
            self.pendingForeignRemoval = agent
            return true
        }
    }

    func setEconomy(_ enabled: Bool) {
        let done = enabled ? String(localized: "agentLibrary.economy.on.note") : String(localized: "agentLibrary.economy.off.note")
        perform(done: done) { store, scope in
            try store.setEconomy(enabled, in: scope)
        }
    }

    func undo() {
        guard let last = lastChange else { return }
        let slot = last.scope.backupSlot
        lastChange = nil
        perform(done: String(localized: "agentLibrary.undone.note"), undoable: false) { store, _ in
            try store.revert(last.change, backupSlot: slot)
        }
    }

    func cancel() {
        work?.cancel()
    }

    private func perform(done: String, undoable: Bool = true,
                         _ action: @escaping @Sendable (AgentLibraryStore, AgentLibraryScope) throws -> AgentLibraryChange,
                         onError: ((AgentLibraryError) -> Bool)? = nil) {
        guard !running else { return }
        running = true
        error = nil
        note = nil
        let store = store
        let scope = scope
        work = Task {
            let result = await Task.detached { Result { try action(store, scope) } }.value
            running = false
            switch result {
            case .success(let change):
                if !change.isEmpty {
                    restartHint = true
                    if undoable { lastChange = (change, scope) }
                }
                note = change.skipped.isEmpty
                    ? done
                    : String(format: String(localized: "agentLibrary.skipped.note"), done, change.skipped.joined(separator: ", "))
            case .failure(let failure):
                if let failure = failure as? AgentLibraryError {
                    if onError?(failure) != true { error = Self.describe(failure) }
                } else {
                    error = failure.localizedDescription
                }
            }
            await refresh()
        }
    }

    static func describe(_ error: AgentLibraryError) -> String {
        switch error {
        case .invalidName(let name):
            String(format: String(localized: "agentLibrary.error.invalidName"), name)
        case .conflict(let name), .notAlethe(let name):
            String(format: String(localized: "agentLibrary.error.notAlethe"), name)
        case .file(.changedSinceRead(let url)):
            String(format: String(localized: "agentLibrary.error.changed"), url.lastPathComponent)
        case .file(.unreadable(let url, let reason)), .file(.backupFailed(let url, let reason)),
             .file(.writeFailed(let url, let reason)):
            String(format: String(localized: "agentLibrary.error.file"), url.lastPathComponent, reason)
        }
    }
}
