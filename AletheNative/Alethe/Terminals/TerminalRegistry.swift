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
        /// The agent's CLI was not found; `command` is the binary looked for.
        case notFound(command: String)
        case failed(message: String)
    }

    private(set) var states: [TabID: State] = [:]
    /// Bumped whenever a tab gets a new view (start, restart) so hosts swap it in.
    private(set) var generations: [TabID: Int] = [:]
    @ObservationIgnored private var views: [TabID: TerminalPaneView] = [:]

    func view(for tab: TabID) -> TerminalPaneView? { views[tab] }

    /// Starts the tab's process unless it already has one (running or ended).
    func ensureStarted(_ tab: PaneTab, in project: Project, environment: AppEnvironment) {
        guard states[tab.id] == nil else { return }
        start(tab, in: project, environment: environment)
    }

    /// Replaces whatever the tab runs with a fresh process.
    func restart(_ tab: PaneTab, in project: Project, environment: AppEnvironment) {
        views.removeValue(forKey: tab.id)?.terminate()
        environment.launchers.invalidate()
        start(tab, in: project, environment: environment)
    }

    /// Ends the tab's process and forgets it (the tab was closed or deleted).
    func close(_ tab: TabID) {
        views.removeValue(forKey: tab)?.terminate()
        states.removeValue(forKey: tab)
        generations.removeValue(forKey: tab)
    }

    /// Closes terminals whose tabs no longer exist.
    func prune(keeping tabs: Set<TabID>) {
        for tab in Set(states.keys).subtracting(tabs) { close(tab) }
    }

    func terminateAll() {
        for tab in Array(states.keys) { close(tab) }
    }

    func applyAppearance(theme: Theme, fontSize: Float) {
        for view in views.values { view.applyTheme(theme, fontSize: fontSize) }
    }

    /// Sends the tab's first prompt once, then forgets it so a relaunch does not send it again.
    private func deliver(_ prompt: String, to view: TerminalPaneView, tab: TabID,
                         style: PromptDelivery.Style, environment: AppEnvironment) {
        Task { [weak environment] in
            guard await view.deliverPrompt(prompt, style: style) else { return }
            environment?.workspace?.update { $0.updateTab(tab) { $0.initialPrompt = nil } }
        }
    }

    private func start(_ tab: PaneTab, in project: Project, environment: AppEnvironment) {
        let kind = AgentKind(rawValue: tab.agent)
        var sessionID = tab.sessionID
        // A Claude session that never got a message has no transcript and cannot be resumed.
        if kind == .claude, let id = sessionID, !ClaudeTranscripts.exists(sessionID: id) { sessionID = nil }
        let request = AgentLaunchRequest(
            kind: kind,
            workingDirectory: tab.workingDirectory ?? project.folder,
            extraArguments: tab.extraArguments,
            sessionID: sessionID,
            unrestricted: tab.unrestricted
        )
        do {
            let command = try environment.agentLauncher.command(for: request)
            let view = try TerminalPaneView(launch: command.ptyLaunch(size: PTYSize(columns: 80, rows: 24)),
                                            theme: environment.theme, fontSize: environment.terminalFontSize)
            view.onExit = { [weak self, weak view] code in
                guard let self, let view, self.views[tab.id] === view else { return }
                self.states[tab.id] = .exited(code: code)
            }
            views[tab.id] = view
            states[tab.id] = .running
            if let prompt = tab.initialPrompt, kind != .shell {
                deliver(prompt, to: view, tab: tab.id, style: kind == .opencode ? .typeAndConfirm : .paste,
                        environment: environment)
            }
            if command.createdSession, let session = command.sessionID {
                // Not undoable: it records what the process is, not a user edit.
                environment.workspace?.update { $0.updateTab(tab.id) { $0.sessionID = session } }
            }
        } catch AgentLaunchError.launcherNotFound(let command) {
            states[tab.id] = .notFound(command: command)
        } catch {
            states[tab.id] = .failed(message: String(describing: error))
        }
        generations[tab.id, default: 0] += 1
    }
}
