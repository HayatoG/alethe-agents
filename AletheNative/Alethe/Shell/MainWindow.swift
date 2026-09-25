import AletheDesign
import AletheModel
import SwiftUI

struct MainWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    /// The window's undo manager: a sheet gets its own, so edits made there would not be undoable
    /// from the main window once it closes.
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("main.columnVisibility") private var sidebarVisible = true

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: metrics.size(200), ideal: metrics.size(240), max: metrics.size(360))
        } detail: {
            WorkspaceView()
                // Inside the detail column: over the whole split view, AppKit's split views take the clicks.
                .overlay(alignment: .bottom) { DictationHUD() }
                .animation(environment.reducesMotion ? nil : .easeOut(duration: 0.2), value: environment.dictation.machine.phase)
                .toolbar {
                    ToolbarItem(placement: .navigation) { HomeButton() }
                    ToolbarItem(placement: .primaryAction) { UsagePills() }
                    ToolbarItem(placement: .primaryAction) { NotificationsButton() }
                    ToolbarItem(placement: .primaryAction) { MemoryIndicator() }
                }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(item: editorRequest) { request in
            if let workspace = environment.workspace {
                editor(for: request, workspace: workspace)
            }
        }
    }

    private var editorRequest: Binding<EditorRequest?> {
        Binding { environment.editorRequest } set: { environment.editorRequest = $0 }
    }

    @ViewBuilder
    private func editor(for request: EditorRequest, workspace: WorkspaceModel) -> some View {
        switch request {
        case .newProject(let location):
            ProjectEditor(workspace: workspace, undoManager: undoManager, editing: nil, initialLocation: location)
        case .editProject(let id):
            ProjectEditor(workspace: workspace, undoManager: undoManager, editing: id, initialLocation: .ungrouped)
        case .newGroup(let parent):
            GroupEditor(workspace: workspace, undoManager: undoManager, editing: nil, initialParent: parent)
        case .editGroup(let id):
            GroupEditor(workspace: workspace, undoManager: undoManager, editing: id, initialParent: nil)
        case .newTerminal(let project):
            NewTerminalSheet(workspace: workspace, undoManager: undoManager,
                             initialProject: project ?? workspace.document.workspace.selectedProjectID)
        case .newSubTab(let pane):
            NewTerminalSheet(workspace: workspace, undoManager: undoManager,
                             initialProject: workspace.document.pane(pane)?.project.id, targetPane: pane)
        case .addContent(let project):
            AddContentSheet(workspace: workspace, undoManager: undoManager,
                            project: project ?? workspace.document.workspace.selectedProjectID)
        case .previewLink(let target):
            LinkPreviewSheet(target: target)
        case .importTauri:
            TauriImportSheet(workspace: workspace, undoManager: undoManager)
        case .layoutDesigner(let project):
            LayoutDesignerSheet(workspace: workspace, undoManager: undoManager, projectID: project)
        case .findJump:
            FindJumpSheet(workspace: workspace, undoManager: undoManager)
        case .conversations(let project):
            ConversationsSheet(workspace: workspace, undoManager: undoManager, initialProject: project)
        case .sessionCost(let tab):
            SessionCostSheet(workspace: workspace, tabID: tab)
        case .handoff(let tab):
            HandoffSheet(workspace: workspace, undoManager: undoManager, tabID: tab)
        case .aiUsage:
            AIUsageSheet()
        }
    }

    /// Sidebar visibility survives relaunch (state restoration).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            sidebarVisible ? .all : .detailOnly
        } set: { visibility in
            sidebarVisible = visibility != .detailOnly
        }
    }
}
