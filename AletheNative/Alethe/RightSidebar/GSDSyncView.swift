import AletheDesign
import AletheIntegrations
import AletheModel
import AlethePluginKit
import SwiftUI

/// Right sidebar GSD Sync tab (P5-24; upstream `GsdSyncSidebarContent`): the selected project's child
/// sessions from the app-wide poll, each opening its activity.
struct GSDSyncView: View {
    @Environment(AppEnvironment.self) private var environment

    static let tabID = "gsdSync"
    static let tab = SidebarTabContribution(id: tabID, title: "GSD Sync", symbol: "arrow.triangle.2.circlepath",
                                            side: .right, viewID: tabID)

    private var project: Project? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)
        }
    }

    var body: some View {
        let sessions = project.map { environment.gsdSync.sessions(of: $0.id) } ?? []
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("gsdSync.empty", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("gsdSync.empty.detail")
                }
                .accessibilityIdentifier("gsdSync.empty")
            } else {
                List(sessions) { session in
                    GSDSyncRow(session: session)
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("gsdSync.list")
            }
        }
    }
}

/// A child session: its state glyph, checkout, state and roadmap progress.
private struct GSDSyncRow: View {
    let session: GSDSyncSession
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button {
            environment.editorRequest = .gsdSyncActivity(GSDSyncActivityTarget(session))
        } label: {
            HStack(spacing: metrics.space(.m)) {
                GSDSyncStateGlyph(session: session)
                VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                    Text(verbatim: session.name).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: metrics.space(.xs)) {
                        Text(GSDSyncStateGlyph.label(for: session))
                        if let progress = GSDPlanningText.progress(session) {
                            Text(verbatim: "·")
                            Text(verbatim: progress)
                        }
                    }
                    .font(metrics.font(.footnote))
                    .foregroundStyle(theme[.textSecondary])
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(metrics.font(.footnote))
                    .foregroundStyle(theme[.textTertiary])
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: session.root.path))
        .accessibilityIdentifier("gsdSync.row.\(session.name)")
    }
}

/// Busy, error or idle, as upstream's row dot.
struct GSDSyncStateGlyph: View {
    let session: GSDSyncSession
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var pulse = false

    static func label(for session: GSDSyncSession) -> LocalizedStringKey {
        session.error != nil ? "gsdSync.state.error" : session.busy ? "gsdSync.state.busy" : "gsdSync.state.idle"
    }

    var body: some View {
        Circle()
            .fill(theme[session.error != nil ? .statusStopped : session.busy ? .statusWorking : .statusIdle])
            .frame(width: metrics.size(7), height: metrics.size(7))
            .opacity(session.busy && session.error == nil && pulse ? 0.35 : 1)
            .animation(session.busy && !metrics.reducesMotion ? .easeInOut(duration: 0.8).repeatForever() : nil, value: pulse)
            .onAppear { pulse = true }
            .help(Text(Self.label(for: session)))
            .accessibilityLabel(Text(Self.label(for: session)))
            .accessibilityIdentifier("gsdSync.state")
    }
}

/// Planning status in words (upstream `todo.gsdProgress`, `Progress:`, complete).
enum GSDPlanningText {
    static func progress(_ session: GSDSyncSession) -> String? {
        if session.planning.reportedComplete { return String(localized: "gsdSync.planning.complete") }
        if let roadmap = session.roadmapProgress { return format("gsdSync.planning.tasks", roadmap.done, roadmap.total) }
        if let percent = session.planning.progress { return format("gsdSync.planning.percent", percent) }
        return nil
    }
}
