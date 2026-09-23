import AletheAgents
import AletheDesign
import AletheModel
import SwiftUI

/// The workspace area: the selected project's focused pane (split layout arrives with P1-6).
struct WorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        ZStack {
            theme[.bg].ignoresSafeArea()
            #if DEBUG
            if UserDefaults.standard.string(forKey: "AletheUITestFixture") == "hit-targets" {
                HitTargetFixture()
            } else {
                content
            }
            #else
            content
            #endif
        }
        .onChange(of: allTabIDs) { _, tabs in environment.terminals.prune(keeping: tabs) }
        .onChange(of: environment.theme) { _, _ in applyAppearance() }
        .onChange(of: environment.terminalFontSize) { _, _ in applyAppearance() }
    }

    @ViewBuilder
    private var content: some View {
        if let project = selectedProject {
            if let tab = visibleTab(in: project) {
                TerminalHost(tab: tab, project: project)
                    .id(tab.id)
            } else {
                projectEmptyState(project)
            }
        } else {
            emptyState
        }
    }

    private var selectedProject: Project? {
        guard let doc = environment.workspace?.document, let id = doc.workspace.selectedProjectID else { return nil }
        return doc.project(id)
    }

    /// The focused pane when it belongs to the project, else its first pane.
    private func visibleTab(in project: Project) -> PaneTab? {
        let focused = environment.workspace?.document.workspace.focusedPaneID
        let pane = project.panes.first { $0.id == focused } ?? project.panes.first
        return pane?.activeTab
    }

    private var allTabIDs: Set<TabID> {
        Set(environment.workspace?.document.projects.flatMap { $0.panes.flatMap { $0.tabs.map(\.id) } } ?? [])
    }

    private func applyAppearance() {
        environment.terminals.applyAppearance(theme: environment.theme, fontSize: environment.terminalFontSize)
    }

    private func projectEmptyState(_ project: Project) -> some View {
        VStack(spacing: metrics.space(.l)) {
            Text(verbatim: project.name)
                .font(metrics.font(.title2))
                .foregroundStyle(theme[.textPrimary])
            Text("workspace.project.noTerminals")
                .font(metrics.font(.body))
                .foregroundStyle(theme[.textSecondary])
            NewTerminalMenu(project: project)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.project.empty")
    }

    private var emptyState: some View {
        VStack(spacing: metrics.space(.m)) {
            Text("workspace.empty.title")
                .font(metrics.font(.title2))
                .foregroundStyle(theme[.textPrimary])
            Text("workspace.empty.message")
                .font(metrics.font(.body))
                .foregroundStyle(theme[.textSecondary])
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: metrics.size(420))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.empty")
    }
}

/// "New Terminal" with the enabled agents; the full sheet (prompt, folder, flags) is P1-9.
struct NewTerminalMenu: View {
    let project: Project
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Menu("terminal.new") {
            ForEach(AgentRegistry.builtin.enabledKinds(environment.preferences?.document.enabledAgents), id: \.self) { kind in
                Button { open(kind) } label: { Text(verbatim: AgentLabels.name(for: kind.rawValue)) }
                    .accessibilityIdentifier("terminal.new.\(kind.rawValue)")
            }
        }
        .accessibilityIdentifier("terminal.new")
    }

    private func open(_ kind: AgentKind) {
        let unrestricted = kind != .shell && (environment.preferences?.document.alwaysStartUnrestricted ?? false)
        environment.workspace?.update(undoManager: undoManager, actionName: String(localized: "undo.newTerminal")) {
            $0.addPane(to: project.id, tab: PaneTab(agent: kind.rawValue, unrestricted: unrestricted))
        }
        environment.preferences?.update { $0.lastAgent = kind.rawValue }
    }
}
