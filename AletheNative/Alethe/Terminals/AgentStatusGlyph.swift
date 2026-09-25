import AletheAgents
import AletheDesign
import AletheModel
import SwiftUI

/// A tab's agent state at a glance (upstream sidebar busy/done glyph): a pulsing dot while working,
/// a question bubble when it waits for an answer, a filled dot when it finished unseen.
struct AgentStatusGlyph: View {
    let tab: TabID
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var pulse = false

    var body: some View {
        let activity = environment.terminals.activity[tab]
        let unread = environment.terminals.unread.contains(tab)
        Group {
            switch activity {
            case .working:
                Circle()
                    .fill(theme[.statusWorking])
                    .frame(width: metrics.size(7), height: metrics.size(7))
                    .opacity(pulse ? 0.35 : 1)
                    .animation(metrics.reducesMotion ? nil : .easeInOut(duration: 0.8).repeatForever(), value: pulse)
                    .onAppear { pulse = true }
                    .help(Text("agentStatus.working"))
                    .accessibilityLabel(Text("agentStatus.working"))
            case .needsInput:
                Image(systemName: "questionmark.bubble.fill")
                    .font(metrics.font(.caption))
                    .foregroundStyle(theme[.statusWaiting])
                    .help(Text("agentStatus.needsInput"))
                    .accessibilityLabel(Text("agentStatus.needsInput"))
            case .done where unread:
                Circle()
                    .fill(theme[.statusActive])
                    .frame(width: metrics.size(7), height: metrics.size(7))
                    .help(Text("agentStatus.done"))
                    .accessibilityLabel(Text("agentStatus.done"))
            default:
                EmptyView()
            }
        }
        .accessibilityIdentifier("agentStatus.\(tab.rawValue)")
    }
}
