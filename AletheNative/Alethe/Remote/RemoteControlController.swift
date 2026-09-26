import AletheAgents
import AletheModel
import AletheRemote
import AletheTerminal
import Foundation
import Observation
import Synchronization

/// Remote control's app service (PER-7; upstream `useRemoteControlService.ts`, `remote/commands.rs`,
/// `pty_bridge.rs`): the hub and API read the workspace and terminals through the sources below;
/// the user's settings are pushed as they change; events become notifications. Off at every launch:
/// nothing binds until `setEnabled(true)`, and `stop` (at quit) revokes every device.
@Observable
@MainActor
final class RemoteControlController {
    /// Whether the user turned it on this session (never saved).
    private(set) var isEnabled = false
    /// The hub's last reported state, for Settings and the pairing sheet.
    private(set) var info: RemoteInfo?
    /// Whether a Tailscale address exists; nil until `refreshTailscale`.
    private(set) var tailscale: RemoteTailscaleStatus?

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var service: RemoteControlService?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Commands run one at a time, in the order the user gave them.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var pushed: RemoteControlSettings?
    /// Tabs shared right now; output of any other tab never leaves the Mac.
    @ObservationIgnored private let sharedIDs = SharedTabIDs()

    func start(environment: AppEnvironment) {
        guard service == nil else { return }
        self.environment = environment
        let service = RemoteControlService(
            hub: RemoteHub(resolver: Self.resolver),
            terminals: RemoteTerminalBridge(backend: Self.terminalBackend(environment, shared: sharedIDs)),
            workspace: RemoteAppWorkspace(environment: environment),
            assets: RemoteClientBundle()
        )
        self.service = service
        eventsTask = Task { [weak self] in
            for await event in service.events {
                self?.handle(event)
            }
        }
        observeSettings()
        observeSharing()
    }

    /// Quitting: listeners and connections close, every device is revoked.
    func stop() async {
        queue?.cancel()
        queue = nil
        isEnabled = false
        guard let service else { return }
        await service.stop()
        info = await service.info()
    }

    // MARK: - Commands

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enqueue { await $0.setEnabled(enabled) }
    }

    func openPairing() {
        enqueue { await $0.openPairing() }
    }

    func closePairing() {
        enqueue { await $0.closePairing() }
    }

    func revoke(deviceID: Int) {
        enqueue { await $0.revoke(deviceID: deviceID) }
    }

    func revokeAll() {
        enqueue { await $0.revokeAll() }
    }

    /// Re-reads the hub (device list, pairing countdown).
    func refresh() {
        enqueue { await $0.info() }
    }

    func refreshTailscale() {
        Task { tailscale = await RemoteHost.tailscaleStatus() }
    }

    /// Shares a terminal pane with paired devices, or stops sharing it.
    func setShared(_ pane: PaneID, _ shared: Bool) {
        environment?.workspace?.update { $0.setRemoteShared(pane, shared) }
    }

    /// What `/api/state` answers right now.
    func snapshot() -> RemoteWorkspaceSnapshot {
        guard let environment, let document = environment.workspace?.document else {
            return RemoteWorkspaceSnapshot(groups: [], projects: [])
        }
        return RemoteAppWorkspace.snapshot(of: document, names: environment.terminals)
    }

    #if DEBUG
    /// UI tests: an event as if the hub emitted it (a stub device message).
    func emitForTesting(_ event: RemoteEvent) {
        service?.hub.emit(event)
    }
    #endif

    private func enqueue(_ operation: @escaping @Sendable (RemoteControlService) async -> RemoteInfo) {
        guard let service else { return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let info = await operation(service)
            guard let self, !Task.isCancelled else { return }
            self.info = info
            self.isEnabled = info.enabled
        }
    }

    // MARK: - Settings and sharing

    /// The user's settings as the hub takes them.
    var settings: RemoteControlSettings {
        let remote = environment?.preferences?.document.remoteSettings ?? RemotePreferences()
        return RemoteControlSettings(maxDevices: remote.maxDevices, sessionExpirySecs: remote.sessionExpirySecs,
                                     readOnly: remote.readOnly, allowShellInput: remote.allowShellInput,
                                     reachMode: remote.useTailscale ? .tailscale : .lan)
    }

    /// Pushes the settings whenever they change; the hub restarts only for a new reach mode.
    private func observeSettings() {
        let current = withObservationTracking { settings } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        guard current != pushed else { return }
        pushed = current
        enqueue { service in
            await service.apply(current)
            return await service.info()
        }
    }

    private func observeSharing() {
        let ids = withObservationTracking {
            Set(environment?.workspace?.document.remoteSharedTerminals.map(\.tab.id.rawValue) ?? [])
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSharing() }
        }
        sharedIDs.set(ids)
    }

    // MARK: - Events

    private func handle(_ event: RemoteEvent) {
        guard let notifier = environment?.notifier else { return }
        switch event {
        case .message(let message):
            let tab = TabID(rawValue: message.terminalID)
            let known = environment?.workspace?.document.paneHolding(tab) != nil
            notifier.post(title: String(format: String(localized: "remote.notify.message"), message.deviceName),
                          body: message.preview, tab: known ? tab : nil)
        case .startFailed:
            isEnabled = false
            notifier.post(title: String(localized: "remote.notify.startFailed.title"),
                          body: String(localized: "remote.notify.startFailed.body"))
            refresh()
        case .autoDisabled:
            isEnabled = false
            notifier.post(title: String(localized: "remote.notify.autoDisabled.title"),
                          body: String(localized: "remote.notify.autoDisabled.body"))
            refresh()
        }
    }

    // MARK: - Sources

    /// The Mac's LAN or Tailscale address. UI-test launches (debug builds) bind loopback only.
    private static var resolver: RemoteHostResolver {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "AletheUITestSeed") != nil || defaults.string(forKey: "AletheRemoteHost") == "127.0.0.1" {
            return RemoteHostResolver(lanAddress: { "127.0.0.1" }, tailscaleAddress: { "127.0.0.1" })
        }
        #endif
        return .system
    }

    /// The terminal registry by tab id (upstream `pty_bridge.rs`).
    private static func terminalBackend(_ environment: AppEnvironment, shared: SharedTabIDs) -> RemoteTerminalBridge.Backend {
        let terminals = environment.terminals
        let relay = terminals.output
        return RemoteTerminalBridge.Backend(
            write: { [weak environment] id, bytes in
                await MainActor.run {
                    let tab = TabID(rawValue: id)
                    guard environment?.workspace?.document.paneHolding(tab) != nil else { return .notFound }
                    return terminals.typeInput(String(decoding: bytes, as: UTF8.self), into: tab) ? .written : .notRunning
                }
            },
            size: { id in
                await MainActor.run { terminals.gridSize(of: TabID(rawValue: id)) }
                    .map { RemoteTerminalSize(cols: Int($0.columns), rows: Int($0.rows)) }
            },
            scrollback: { [weak environment] id, maxBytes in
                let tab = TabID(rawValue: id)
                let file = await MainActor.run { terminals.scrollbackFile(of: tab) ?? environment?.scrollbackFile(for: tab) }
                guard let file else { return Data() }
                return await TerminalRegistry.scrollbackTail(file, maxBytes: maxBytes)
            },
            observe: { handler in
                let id = relay.observe { event in
                    switch event {
                    case .data(let tab, let data):
                        guard shared.contains(tab.rawValue) else { return }
                        handler(.data(terminalID: tab.rawValue, bytes: data))
                    case .exit(let tab, let reason):
                        guard shared.contains(tab.rawValue) else { return }
                        handler(.exit(terminalID: tab.rawValue, reason: reason))
                    }
                }
                return { relay.remove(id) }
            }
        )
    }
}

/// The ids of the shared tabs, read by the output relay on the PTY queues.
final class SharedTabIDs: Sendable {
    private let ids = Mutex<Set<String>>([])

    func set(_ value: Set<String>) { ids.withLock { $0 = value } }
    func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
}

/// The workspace as remote devices see it (upstream `remote/workspace.rs`, `appearance.rs`): only
/// tabs of shared panes; transcripts and questions through `Handoff`, off the main thread.
@MainActor
final class RemoteAppWorkspace: RemoteWorkspaceSource {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func sharedTabs() async -> [RemoteSharedTab] {
        guard let document = environment?.workspace?.document else { return [] }
        return document.remoteSharedTerminals.map { shared in
            RemoteSharedTab(terminalID: shared.tab.id.rawValue, agent: shared.tab.agent, cwd: shared.cwd,
                            sessionID: shared.tab.sessionID.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func snapshot() async -> RemoteWorkspaceSnapshot {
        guard let environment, let document = environment.workspace?.document else {
            return RemoteWorkspaceSnapshot(groups: [], projects: [])
        }
        return Self.snapshot(of: document, names: environment.terminals)
    }

    /// Groups, and every project with its shared tabs only (upstream `workspace_snapshot`).
    static func snapshot(of document: WorkspaceDocument, names: TerminalRegistry) -> RemoteWorkspaceSnapshot {
        let groups = document.groups.map {
            RemoteWorkspaceSnapshot.Group(id: $0.id.rawValue, name: $0.name, color: $0.color?.rawValue)
        }
        let projects = document.projects.map { project in
            let chats = document.remoteSharedTerminals(in: project).map { shared in
                RemoteWorkspaceSnapshot.Chat(id: shared.tab.id.rawValue, ptyId: shared.tab.id.rawValue,
                                             name: names.displayName(of: shared.tab), agent: shared.tab.agent,
                                             terminalId: shared.paneID.rawValue)
            }
            return RemoteWorkspaceSnapshot.Project(id: project.id.rawValue, name: project.name,
                                                   groupId: document.groupID(holding: project.id)?.rawValue,
                                                   color: project.color.rawValue, chats: chats)
        }
        return RemoteWorkspaceSnapshot(groups: groups, projects: projects)
    }

    func appearance() async -> RemoteAppearance {
        guard let environment, let preferences = environment.preferences?.document else { return .fallback }
        let language = environment.launchLanguage == .system
            ? Bundle.main.preferredLocalizations.first
            : environment.launchLanguage.rawValue
        return .resolved(uiTheme: preferences.themeID, appIconTheme: preferences.iconTheme.rawValue,
                         language: language, motionPreference: environment.reducesMotion ? "reduced" : "animated")
    }

    func transcript(for tab: RemoteSharedTab, since: UInt64?, limit: Int) async throws -> RemoteTranscript {
        let kind = AgentKind(rawValue: tab.agent)
        let snapshot = await Task.detached(priority: .utility) {
            Handoff.transcriptSnapshot(agent: kind, folder: tab.cwd, session: tab.sessionID, since: since, limit: limit)
        }.value
        return RemoteTranscript(sessionId: snapshot.sessionID, revision: snapshot.revision, unchanged: snapshot.unchanged,
                                messages: snapshot.messages.map(Self.message))
    }

    func activeQuestions(for tab: RemoteSharedTab) async -> RemoteQuestionSet? {
        let kind = AgentKind(rawValue: tab.agent)
        let active = await Task.detached(priority: .utility) {
            Handoff.activeQuestions(agent: kind, folder: tab.cwd, session: tab.sessionID)
        }.value
        return active.map { RemoteQuestionSet(id: $0.id, questions: $0.questions.map(Self.question)) }
    }

    nonisolated static func message(_ event: Handoff.Event) -> RemoteTranscript.Message {
        RemoteTranscript.Message(role: event.role.rawValue, text: event.text, questionSetId: event.questionSetID,
                                 questions: event.questions?.map(question))
    }

    nonisolated static func question(_ question: Handoff.RemoteQuestion) -> RemoteQuestion {
        RemoteQuestion(id: question.id, header: question.header, question: question.question,
                       multiSelect: question.multiSelect,
                       options: question.options.map { RemoteQuestionOption(label: $0.label, description: $0.description) })
    }
}
