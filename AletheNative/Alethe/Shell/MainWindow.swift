import AletheDesign
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
