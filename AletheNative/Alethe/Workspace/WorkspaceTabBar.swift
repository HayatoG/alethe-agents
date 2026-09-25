import AletheDesign
import AletheModel
import SwiftUI

/// Workspace tabs above the panes (upstream TitleBar tabs): back/forward, one tab per saved view,
/// pinned tabs first. Click shows a tab, the close button closes it (⇧⌘T reopens), the context menu
/// pins it; tabs reorder by dragging.
struct WorkspaceTabBar: View {
    let workspace: WorkspaceModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var hovered: WorkspaceTabID?
    @State private var dragging: WorkspaceTabID?

    private var document: WorkspaceDocument { workspace.document }

    var body: some View {
        HStack(spacing: metrics.space(.xs)) {
            navigationButton("chevron.left", label: "menu.view.back", id: "workspaceTabs.back",
                             enabled: document.canGoBack) { workspace.update { $0.navigateHistory(-1) } }
            navigationButton("chevron.right", label: "menu.view.forward", id: "workspaceTabs.forward",
                             enabled: document.canGoForward) { workspace.update { $0.navigateHistory(1) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.space(.xxs)) {
                    ForEach(document.workspace.tabs) { tab in
                        tabView(tab)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.space(.m))
        .frame(height: metrics.size(32))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme[.bgSunken])
        .overlay(alignment: .bottom) { theme[.borderSubtle].frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspaceTabs")
    }

    private func tabView(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == document.workspace.activeTabID
        let label = document.label(of: tab)
        let name = label?.name ?? String(localized: "workspaceTabs.empty")
        return HStack(spacing: metrics.space(.s)) {
            if tab.pinned {
                Image(systemName: "pin.fill")
                    .font(metrics.font(.caption))
                    .foregroundStyle(theme[.textTertiary])
            }
            Circle()
                .fill(document.color(of: tab).map { theme[$0.token] } ?? theme[.fgFaint])
                .frame(width: metrics.size(7), height: metrics.size(7))
            Text(verbatim: name)
                .font(metrics.font(.footnote).weight(isActive ? .semibold : .regular))
                .foregroundStyle(theme[isActive ? .textPrimary : .textSecondary])
                .lineLimit(1)
            if let more = label?.more, more > 0 {
                Text(verbatim: "+\(more)")
                    .font(metrics.font(.caption).monospacedDigit())
                    .foregroundStyle(theme[.textTertiary])
            }
            Button {
                workspace.update { $0.closeWorkspaceTab(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(metrics.font(.caption).weight(.semibold))
                    .frame(width: metrics.size(14), height: metrics.size(14))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme[.textTertiary])
            .opacity(isActive || hovered == tab.id ? 1 : 0)
            .help(Text("workspaceTabs.close"))
            .accessibilityLabel(Text("workspaceTabs.close"))
            .accessibilityIdentifier("workspaceTabs.close.\(name)")
        }
        .padding(.horizontal, metrics.space(.m))
        .frame(height: metrics.size(24))
        .background(
            RoundedRectangle(cornerRadius: metrics.radius(.sm))
                .fill(theme[isActive ? .panel : (hovered == tab.id ? .panelHover : .bgSunken)])
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius(.sm))
                .strokeBorder(theme[isActive ? .border : .bgSunken], lineWidth: 1)
        )
        .opacity(dragging == tab.id ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .onTapGesture { workspace.update { $0.activateWorkspaceTab(tab.id) } }
        .onDrag {
            dragging = tab.id
            return NSItemProvider(object: tab.id.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, dragging: $dragging, workspace: workspace))
        .contextMenu {
            Button(tab.pinned ? LocalizedStringKey("workspaceTabs.unpin") : "workspaceTabs.pin") {
                workspace.update { $0.togglePinned(tab.id) }
            }
            Divider()
            Button("workspaceTabs.close") { workspace.update { $0.closeWorkspaceTab(tab.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityIdentifier("workspaceTabs.tab.\(name)")
    }

    private func navigationButton(_ symbol: String, label: LocalizedStringKey, id: String, enabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.font(.caption).weight(.semibold))
                .frame(width: metrics.size(20), height: metrics.size(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme[enabled ? .textSecondary : .textQuaternary])
        .disabled(!enabled)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}

/// Reorders tabs live while one is dragged over another.
private struct TabDropDelegate: DropDelegate {
    let target: WorkspaceTabID
    @Binding var dragging: WorkspaceTabID?
    let workspace: WorkspaceModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != target,
                  let index = workspace.document.workspace.tabs.firstIndex(where: { $0.id == target }) else { return }
            workspace.update { $0.moveWorkspaceTab(dragging, to: index) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
