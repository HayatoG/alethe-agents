import AletheDesign
import AletheModel
import SwiftUI

/// Title bar of a project container: color, name, close.
struct ContainerHeader: View {
    let project: Project
    let isSelected: Bool
    let onClose: () -> Void
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
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(metrics.font(.caption).weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme[.textTertiary])
            .help(Text("workspace.container.close"))
            .accessibilityLabel(Text("workspace.container.close"))
            .accessibilityIdentifier("container.close.\(project.name)")
        }
        .padding(.horizontal, metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[.bgElevated])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("container.\(project.name)")
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
    let onClose: () -> Void
    let onNewSubTab: () -> Void
    let onToggleLane: () -> Void
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
