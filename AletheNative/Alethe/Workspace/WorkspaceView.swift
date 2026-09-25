import AletheDesign
import AletheModel
import SwiftUI

/// The workspace area: open projects as containers of panes (`PaneHost`), or the empty state.
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
        .onChange(of: environment.workspace?.document.currentSnapshot) { _, _ in
            environment.workspace?.update { $0.syncActiveTab() }
        }
        .onChange(of: allTabIDs) { _, tabs in environment.terminals.prune(keeping: tabs) }
        .onChange(of: allPaneIDs) { _, panes in environment.contentPanes.prune(keeping: panes) }
        .onChange(of: environment.theme) { _, _ in applyAppearance() }
        .onChange(of: environment.terminalFontSize) { _, _ in applyAppearance() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let workspace = environment.workspace, !workspace.document.workspace.tabs.isEmpty {
                WorkspaceTabBar(workspace: workspace)
            }
            if let doc = environment.workspace?.document, !doc.workspace.openProjectIDs.isEmpty {
                PaneHost(document: doc, terminalStates: environment.terminals.states,
                         terminalGenerations: environment.terminals.generations)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var allTabIDs: Set<TabID> {
        Set(environment.workspace?.document.projects.flatMap { $0.panes.flatMap { $0.tabs.map(\.id) } } ?? [])
    }

    private var allPaneIDs: Set<PaneID> {
        Set(environment.workspace?.document.projects.flatMap { $0.panes.map(\.id) } ?? [])
    }

    private func applyAppearance() {
        environment.terminals.applyAppearance(theme: environment.theme, fontSize: environment.terminalFontSize)
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

/// Opens the new-terminal sheet for a project.
struct NewTerminalButton: View {
    let project: Project
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button("terminal.new") { environment.editorRequest = .newTerminal(project.id) }
            .accessibilityIdentifier("terminal.new")
    }
}
