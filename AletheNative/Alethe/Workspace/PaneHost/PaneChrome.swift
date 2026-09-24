import AletheDesign
import AletheModel
import SwiftUI

/// Title bar of a project container: color, name, collapse, show alone (fullscreen), close. Dragging
/// it moves the container among the open ones.
struct ContainerHeader: View {
    let project: Project
    let isSelected: Bool
    let isFullscreen: Bool
    let onCollapse: () -> Void
    let onFullscreen: () -> Void
    let onClose: () -> Void
    let onDrag: (CGSize?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.space(.m)) {
            Circle()
                .fill(theme[project.color.token])
                .frame(width: metrics.size(8), height: metrics.size(8))
            Text(verbatim: project.name)
                .font(metrics.font(.headline))
                .foregroundStyle(theme[isSelected ? .textPrimary : .textSecondary])
                .lineLimit(1)
            Spacer(minLength: 0)
            if !isFullscreen {
                headerButton("sidebar.left", label: "workspace.container.collapse", id: "container.collapse.\(project.name)",
                             action: onCollapse)
            }
            headerButton(isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         label: isFullscreen ? "workspace.container.showAll" : "workspace.container.showAlone",
                         id: "container.fullscreen.\(project.name)", action: onFullscreen)
            headerButton("xmark", label: "workspace.container.close", id: "container.close.\(project.name)", action: onClose)
        }
        .padding(.horizontal, metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[.bgElevated])
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDrag(nil) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("container.\(project.name)")
    }

    private func headerButton(_ symbol: String, label: LocalizedStringKey, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.font(.caption).weight(.semibold))
                .frame(width: metrics.size(18), height: metrics.size(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme[.textTertiary])
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}

/// A collapsed container: a narrow strip with the project's color and vertical name; clicking it
/// expands the container, dragging it moves it.
struct CollapsedContainerStrip: View {
    let project: Project
    let isSelected: Bool
    let onExpand: () -> Void
    let onDrag: (CGSize?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.space(.m)) {
            Circle()
                .fill(theme[project.color.token])
                .frame(width: metrics.size(8), height: metrics.size(8))
            Text(verbatim: project.name)
                .font(metrics.font(.footnote).weight(.medium))
                .foregroundStyle(theme[isSelected ? .textPrimary : .textSecondary])
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: metrics.size(18))
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.vertical, metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[.bgElevated], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
        .overlay(RoundedRectangle(cornerRadius: metrics.radius(.md)).strokeBorder(theme[.border]))
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDrag(nil) }
        )
        .help(Text("workspace.container.expand"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: project.name))
        .accessibilityHint(Text("workspace.container.expand"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onExpand() }
        .accessibilityIdentifier("container.collapsed.\(project.name)")
    }
}

/// Title bar of a pane: agent, title, close. Dragging it reorders the pane; its context menu adds a
/// sub-tab and shows or hides the sub-tabs lane.
struct PaneHeader: View {
    let tab: PaneTab
    let isFocused: Bool
    let isLaneVisible: Bool
    /// The lane can only be hidden while the pane has a single tab.
    let canHideLane: Bool
    let isIsolated: Bool
    let onClose: () -> Void
    let onNewSubTab: () -> Void
    let onToggleLane: () -> Void
    let onToggleIsolation: () -> Void
    /// Translation of an ongoing header drag, in the header's coordinates; nil when it ends.
    let onDrag: (CGSize?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.space(.s)) {
            Circle()
                .fill(theme[AgentTokens.accent(for: tab.agent)])
                .frame(width: metrics.size(6), height: metrics.size(6))
            Text(verbatim: tab.title ?? AgentLabels.name(for: tab.agent))
                .font(metrics.font(.footnote).weight(.medium))
                .foregroundStyle(theme[isFocused ? .textPrimary : .textSecondary])
                .lineLimit(1)
            if tab.unrestricted {
                Image(systemName: "bolt.fill")
                    .font(metrics.font(.caption))
                    .foregroundStyle(theme[.statusWaiting])
                    .help(Text("pane.unrestricted"))
                    .accessibilityLabel(Text("pane.unrestricted"))
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(metrics.font(.caption).weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme[.textTertiary])
            .help(Text("pane.close"))
            .accessibilityLabel(Text("pane.close"))
            .accessibilityIdentifier("pane.close")
        }
        .padding(.horizontal, metrics.space(.m))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[isFocused ? .bgElevated : .bgSunken])
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDrag(nil) }
        )
        .contextMenu {
            Button("subtabs.newEllipsis", action: onNewSubTab)
            Button(isLaneVisible ? LocalizedStringKey("subtabs.hideLane") : "subtabs.showLane", action: onToggleLane)
                .disabled(isLaneVisible && !canHideLane)
            Button(isIsolated ? LocalizedStringKey("pane.showAll") : "pane.showAlone", action: onToggleIsolation)
            Divider()
            Button("pane.close", action: onClose)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane.header.\(tab.title ?? tab.agent)")
    }
}

enum AgentTokens {
    static func accent(for agent: String) -> ThemeToken {
        switch agent {
        case "claude": .agentClaude
        case "codex": .agentCodex
        case "opencode": .agentOpencode
        case "cursor": .agentCursor
        default: .agentShell
        }
    }
}
