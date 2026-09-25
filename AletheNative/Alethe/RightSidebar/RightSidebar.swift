import AlethePluginKit
import AletheTodos
import SwiftUI

/// Maps a contributed `viewID` to the app's SwiftUI view and localized title (ADR-9).
enum PluginViewRegistry {
    static func title(for tab: SidebarTabContribution) -> LocalizedStringKey {
        switch tab.viewID {
        case TodosPlugin.viewID: "rightSidebar.todos"
        case DocsView.tabID: "rightSidebar.docs"
        case PullRequestsView.tabID: "rightSidebar.pullRequests"
        default: LocalizedStringKey(tab.title)
        }
    }

    @MainActor @ViewBuilder
    static func view(for viewID: String) -> some View {
        switch viewID {
        case TodosPlugin.viewID: TodosView()
        case DocsView.tabID: DocsView()
        case PullRequestsView.tabID: PullRequestsView()
        default: ContentUnavailableView("rightSidebar.unavailable", systemImage: "puzzlepiece.extension")
        }
    }
}

/// The inspector column (P4-3): the right-side contributed tabs, in `ViewPlacements` order.
struct RightSidebar: View {
    @Environment(AppEnvironment.self) private var environment

    private var tabs: [SidebarTabContribution] {
        // The app's own tabs (Docs, Pull Requests) follow the plugin tabs.
        let own = [DocsView.tab, PullRequestsView.tab]
        guard let plugins = environment.plugins else { return own }
        return plugins.viewPlacements.arranged(plugins.contributions.sidebarTabs).right + own
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
