import AletheAgents
import AletheDesign
import AletheModel
import AletheTerminal
import Foundation
import Observation

/// Live terminals, one per tab. A terminal outlives the view showing it: switching projects or
/// collapsing a pane only detaches its view, the process keeps running.
@Observable
@MainActor
final class TerminalRegistry {
    enum State: Equatable {
        case running
        case exited(code: Int32)
        /// Ended by a double ⌃C.
        case forceKilled
        /// The agent's CLI was not found; `command` is the binary looked for.
        case notFound(command: String)
        case failed(message: String)
    }

    private(set) var states: [TabID: State] = [:]
    /// Bumped whenever a tab gets a new view (start, restart) so hosts swap it in.
    private(set) var generations: [TabID: Int] = [:]
    @ObservationIgnored private var views: [TabID: TerminalPaneView] = [:]
    @ObservationIgnored private var claims = SessionClaims()
    /// How each live process was started, for the early-exit fallback.
    @ObservationIgnored private var launches: [TabID: (startedAt: ContinuousClock.Instant, resumed: Bool)] = [:]
    /// Tabs that already fell back to a fresh session once; a second quick exit is shown, not retried.
    @ObservationIgnored private var retriedFresh: Set<TabID> = []
    /// One saved-output file per tab, shared by every process the tab runs, so clearing, loading and
    /// appending stay in order on its queue.
    @ObservationIgnored private var scrollbacks: [TabID: ScrollbackFile] = [:]
    /// Discovery of a new Codex session, per tab, until its id is found.
    @ObservationIgnored private var discoveries: [TabID: Task<Void, Never>] = [:]

    func view(for tab: TabID) -> TerminalPaneView? { views[tab] }

    /// Starts the tab's process unless it already has one (running or ended).
    func ensureStarted(_ tab: PaneTab, in project: Project, environment: AppEnvironment) {
        guard states[tab.id] == nil else { return }
        start(tab, in: project, environment: environment)
    }

    /// Replaces whatever the tab runs with a fresh process.
    func restart(_ tab: PaneTab, in project: Project, environment: AppEnvironment) {
        restart(tab, in: project, environment: environment, fresh: false)
    }

    private func restart(_ tab: PaneTab, in project: Project, environment: AppEnvironment, fresh: Bool) {
        views.removeValue(forKey: tab.id)?.terminate()
        // A restart starts clean, like upstream's `restart_pty`.
        scrollback(for: tab.id, environment: environment)?.clear()
        environment.launchers.invalidate()
        start(tab, in: project, environment: environment, fresh: fresh)
    }

    /// Ends the tab's process and forgets it (the tab was closed or deleted); its saved scrollback
    /// goes too unless `keepScrollback` (quitting).
    func close(_ tab: TabID, keepScrollback: Bool = false) {
        let view = views.removeValue(forKey: tab)
        if let file = scrollbacks.removeValue(forKey: tab) {
            if keepScrollback { file.flush() } else { file.delete() }
        }
        view?.terminate()
        states.removeValue(forKey: tab)
        generations.removeValue(forKey: tab)
        discoveries.removeValue(forKey: tab)?.cancel()
        launches.removeValue(forKey: tab)
        retriedFresh.remove(tab)
        claims.release(owner: tab.rawValue)
    }

    /// Closes terminals whose tabs no longer exist.
    func prune(keeping tabs: Set<TabID>) {
        for tab in Set(states.keys).subtracting(tabs) { close(tab) }
    }

    /// Quitting: every process ends, every scrollback is written for the next launch.
    func terminateAll() {
        for tab in Array(states.keys) { close(tab, keepScrollback: true) }
    }

    func applyAppearance(theme: Theme, fontSize: Float) {
        for view in views.values { view.applyTheme(theme, fontSize: fontSize) }
    }

    private func scrollback(for tab: TabID, environment: AppEnvironment) -> ScrollbackFile? {
        if let file = scrollbacks[tab] { return file }
        let file = environment.scrollbackFile(for: tab)
        scrollbacks[tab] = file
        return file
    }

    /// Sends the tab's first prompt once, then forgets it so a relaunch does not send it again.
    private func deliver(_ prompt: String, to view: TerminalPaneView, tab: TabID,
                         style: PromptDelivery.Style, environment: AppEnvironment) {
        Task { [weak environment] in
            guard await view.deliverPrompt(prompt, style: style) else { return }
            environment?.workspace?.update { $0.updateTab(tab) { $0.initialPrompt = nil } }
        }
    }

    /// Whether to resume the tab's saved conversation: it must still exist on disk and not be held
    /// by another tab (Codex rejects a second writer; two panes on one Claude chat would interleave).
    private func resumableSession(of tab: PaneTab, kind: AgentKind, cwd: String, fresh: Bool) -> String? {
        guard !fresh, let id = tab.sessionID else { return nil }
        if claims.isClaimed(kind, cwd: cwd, sessionID: id, excluding: tab.id.rawValue) { return nil }
        return SessionResume.isResumable(kind, sessionID: id, cwd: cwd) ? id : nil
    }

    /// Binds the Codex session this tab's process creates, once the CLI writes it to disk.
    private func discoverSession(for tab: TabID, kind: AgentKind, cwd: String, before: Set<String>,
                                 environment: AppEnvironment) {
        discoveries[tab] = Task { [weak self, weak environment] in
            let found = await SessionResume.discover(sleep: { try? await Task.sleep(for: $0) }) {
                let sessions = await Task.detached { CodexSessions.snapshot(cwd: cwd) }.value
                return self?.claims.claimDiscovered(kind, cwd: cwd, before: before, sessions: sessions,
                                                    owner: tab.rawValue)?.id
            }
            guard let found, let self, !Task.isCancelled else { return }
            self.discoveries.removeValue(forKey: tab)
            environment?.workspace?.update { $0.updateTab(tab) { $0.sessionID = found } }
        }
    }

    private func start(_ tab: PaneTab, in project: Project, environment: AppEnvironment, fresh: Bool = false) {
        let kind = AgentKind(rawValue: tab.agent)
        let cwd = tab.workingDirectory ?? project.folder
        discoveries.removeValue(forKey: tab.id)?.cancel()
        claims.release(owner: tab.id.rawValue)
        let sessionID = resumableSession(of: tab, kind: kind, cwd: cwd, fresh: fresh)
        let request = AgentLaunchRequest(
            kind: kind,
            workingDirectory: cwd,
            extraArguments: tab.extraArguments,
            sessionID: sessionID,
            unrestricted: tab.unrestricted
        )
        do {
            let command = try environment.agentLauncher.command(for: request)
            // Taken before the spawn so the session the process creates is the only new one.
            let before = SessionResume.discoversNewSessions(kind) && command.sessionID == nil
                ? Set(CodexSessions.snapshot(cwd: cwd).map(\.id)) : nil
            let view = try TerminalPaneView(launch: command.ptyLaunch(size: PTYSize(columns: 80, rows: 24)),
                                            theme: environment.theme, fontSize: environment.terminalFontSize,
                                            forceKillNotice: String(localized: "terminal.forceKilled"),
                                            promptHistory: environment.promptHistory?.document.histories[tab.id.rawValue] ?? [],
                                            scrollback: scrollback(for: tab.id, environment: environment))
            view.onOpenLink = { [weak environment, weak view] link in
                guard let environment, let view else { return }
                environment.openTerminalLink(link, from: view, tab: tab, project: project)
            }
            view.onPromptHistoryChange = { [weak environment] entries in
                environment?.promptHistory?.update { $0.histories[tab.id.rawValue] = entries }
            }
            view.onExit = { [weak self, weak view, weak environment] code in
                guard let self, let view, self.views[tab.id] === view else { return }
                // A double ⌃C is the user's choice, not a failed resume: show it ended.
                if !view.wasForceKilled, let launch = self.launches[tab.id], let environment,
                   SessionResume.shouldRetryFresh(resumed: launch.resumed, elapsed: .now - launch.startedAt,
                                                  alreadyRetried: self.retriedFresh.contains(tab.id)) {
                    // The saved conversation is gone or unusable: start over without it.
                    self.retriedFresh.insert(tab.id)
                    self.restart(tab, in: project, environment: environment, fresh: true)
                    return
                }
                self.states[tab.id] = view.wasForceKilled ? .forceKilled : .exited(code: code)
            }
            views[tab.id] = view
            states[tab.id] = .running
            launches[tab.id] = (.now, sessionID != nil)
            if let prompt = tab.initialPrompt, kind != .shell {
                deliver(prompt, to: view, tab: tab.id, style: kind == .opencode ? .typeAndConfirm : .paste,
                        environment: environment)
            }
            if let session = command.sessionID {
                claims.register(kind, cwd: cwd, sessionID: session, owner: tab.id.rawValue)
            }
            if command.sessionID != tab.sessionID, kind != .shell {
                // Not undoable: it records what the process is, not a user edit.
                environment.workspace?.update { $0.updateTab(tab.id) { $0.sessionID = command.sessionID } }
            }
            if let before {
                discoverSession(for: tab.id, kind: kind, cwd: cwd, before: before, environment: environment)
            }
        } catch AgentLaunchError.launcherNotFound(let command) {
            states[tab.id] = .notFound(command: command)
        } catch {
            states[tab.id] = .failed(message: String(describing: error))
        }
        generations[tab.id, default: 0] += 1
    }
}
