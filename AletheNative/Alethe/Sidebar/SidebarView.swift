import AletheDesign
import AletheModel
import SwiftUI

/// Projects and groups (the full tree, reordering and context menus arrive with P1-4).
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.metrics) private var metrics

    var body: some View {
        List {
            Section("sidebar.projects.header") {
                ForEach(environment.workspace?.document.projects ?? []) { project in
                    Text(verbatim: project.name)
                        .font(metrics.font(.body))
                }
            }
        }
        .listStyle(.sidebar)
    }
}
