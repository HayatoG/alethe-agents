import AletheDesign
import AletheModel
import SwiftUI

struct MainWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @SceneStorage("main.columnVisibility") private var sidebarVisible = true

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: metrics.size(200), ideal: metrics.size(240), max: metrics.size(360))
        } detail: {
            WorkspaceView()
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
            ProjectEditor(workspace: workspace, editing: nil, initialLocation: location)
        case .editProject(let id):
            ProjectEditor(workspace: workspace, editing: id, initialLocation: .ungrouped)
        case .newGroup(let parent):
            GroupEditor(workspace: workspace, editing: nil, initialParent: parent)
        case .editGroup(let id):
            GroupEditor(workspace: workspace, editing: id, initialParent: nil)
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
