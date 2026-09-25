import AlethePluginKit
import AletheGitControl
import AletheModel
import AletheTodos
import SwiftUI

/// Maps a contributed `viewID` to the app's SwiftUI view and localized title (ADR-9).
enum PluginViewRegistry {
    static func title(for tab: SidebarTabContribution) -> LocalizedStringKey {
        switch tab.viewID {
        case TodosPlugin.viewID: "rightSidebar.todos"
        case DocsView.tabID: "rightSidebar.docs"
        case PullRequestsView.tabID: "rightSidebar.pullRequests"
        case FilesView.tabID: "rightSidebar.files"
        case GSDSyncView.tabID: "rightSidebar.gsdSync"
        case McpPanel.tabID: "rightSidebar.mcp"
        default: LocalizedStringKey(tab.title)
        }
    }

    @MainActor @ViewBuilder
    static func view(for viewID: String) -> some View {
        switch viewID {
        case TodosPlugin.viewID: TodosView()
        case DocsView.tabID: DocsView()
        case PullRequestsView.tabID: PullRequestsView()
        case FilesView.tabID: FilesView()
        case GSDSyncView.tabID: GSDSyncView()
        case McpPanel.tabID: McpPanel()
        default: ExtensionOrUnavailable(viewID: viewID)
        }
    }

    /// The sheet a `SheetContribution` names, for a project.
    @MainActor @ViewBuilder
    static func sheet(for viewID: String, workspace: WorkspaceModel, undoManager: UndoManager?,
                      projectID: ProjectID?) -> some View {
        switch viewID {
        case GitControlPlugin.viewID:
            GitControlSheet(workspace: workspace, undoManager: undoManager, projectID: projectID)
        default:
            ContentUnavailableView("rightSidebar.unavailable", systemImage: "puzzlepiece.extension")
        }
    }
}

/// A third-party extension's tab (P4-19), or a placeholder for an unknown `viewID`.
private struct ExtensionOrUnavailable: View {
    let viewID: String
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let identity = environment.extensions?.identity(forViewID: viewID) {
            ExtensionTabView(identity: identity)
        } else {
            ContentUnavailableView("rightSidebar.unavailable", systemImage: "puzzlepiece.extension")
        }
    }

    /// The sheet a `SheetContribution` names, for a project.
    @MainActor @ViewBuilder
    static func sheet(for viewID: String, workspace: WorkspaceModel, undoManager: UndoManager?,
                      projectID: ProjectID?) -> some View {
        switch viewID {
        case GitControlPlugin.viewID:
            GitControlSheet(workspace: workspace, undoManager: undoManager, projectID: projectID)
        default:
            ContentUnavailableView("rightSidebar.unavailable", systemImage: "puzzlepiece.extension")
        }
    }
}

/// The inspector column (P4-3): the right-side contributed tabs, in `ViewPlacements` order.
struct RightSidebar: View {
    @Environment(AppEnvironment.self) private var environment

    private var tabs: [SidebarTabContribution] {
        // The app's own tabs (Files, Docs, Pull Requests, GSD Sync, MCP) follow the plugin tabs.
        let own = [FilesView.tab, DocsView.tab] + (environment.features.isOn(.prs) ? [PullRequestsView.tab] : [])
            + (environment.gsdSync.isAvailable(in: selectedProject) ? [GSDSyncView.tab] : [])
            + (environment.features.isOn(.mcp) ? [McpPanel.tab] : [])
        let extensions = environment.extensions?.sidebarTabs ?? []
        guard let plugins = environment.plugins else { return extensions + own }
        return plugins.viewPlacements.arranged(plugins.contributions.sidebarTabs).right + extensions + own
    }

    private var selectedProject: Project? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)
        }
    }

    private var selected: SidebarTabContribution? {
        tabs.first { $0.id == environment.rightSidebarTab } ?? tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                Picker("rightSidebar.tabs", selection: selection) {
                    ForEach(tabs, id: \.id) { tab in
                        Label(PluginViewRegistry.title(for: tab), systemImage: tab.symbol).tag(Optional(tab.id))
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .accessibilityIdentifier("rightSidebar.tabs")
                .padding(8)
            }
            if let selected {
                PluginViewRegistry.view(for: selected.viewID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("rightSidebar.empty", systemImage: "sidebar.right")
            }
        }
    }

    private var selection: Binding<String?> {
        Binding { selected?.id } set: { environment.rightSidebarTab = $0 }
    }
}
