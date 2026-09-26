import AletheDesign
import AletheOrchestrator
import SwiftUI

/// Sizes on the board canvas: the UI scale times the board's own zoom, so a node's text, padding
/// and width grow together and the layout's canvas units stay valid at every zoom. Nothing on the
/// canvas uses `scaleEffect` (the zoom rule): each node is laid out at its zoomed size.
struct BoardUnits {
    let metrics: Metrics
    let zoom: CGFloat

    /// Screen points per canvas unit.
    var unit: CGFloat { metrics.scale * zoom }

    func space(_ space: Metrics.Space) -> CGFloat { space.rawValue * unit }
    func size(_ points: CGFloat) -> CGFloat { points * unit }
    func radius(_ radius: Metrics.Radius) -> CGFloat { metrics.radius(radius) * zoom }
    func font(_ style: TextStyle) -> Font { metrics.font(style, zoom: zoom) }
}

extension RunLane {
    /// Upstream `data-lane` colors.
    var token: ThemeToken {
        switch self {
        case .running: .statusWorking
        case .queued, .interrupted, .blocked: .statusWaiting
        case .failed: .statusOffline
        case .finished: .statusStopped
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .blocked: "orchestrator.lane.blocked"
        case .running: "orchestrator.lane.running"
        case .queued: "orchestrator.lane.queued"
        case .interrupted: "orchestrator.lane.interrupted"
        case .failed: "orchestrator.lane.failed"
        case .finished: "orchestrator.lane.finished"
        }
    }

    /// Why a lane needs the person, for the ones that do.
    var explanation: LocalizedStringKey? {
        switch self {
        case .blocked: "orchestrator.blockedTitle"
        case .interrupted: "orchestrator.interruptedTitle"
        default: nil
        }
    }
}

extension JobStatus {
    var title: LocalizedStringKey {
        switch self {
        case .queued: "orchestrator.status.queued"
        case .running: "orchestrator.status.running"
        case .blocked: "orchestrator.status.blocked"
        case .done: "orchestrator.status.done"
        case .failed: "orchestrator.status.failed"
        case .cancelled: "orchestrator.status.cancelled"
        case .released: "orchestrator.status.released"
        case .interrupted: "orchestrator.status.interrupted"
        }
    }
}

extension RunAttention {
    /// `3 failed`, `1 waiting on you`…
    var text: String {
        let key: String.LocalizationValue = switch lane {
        case .blocked: "orchestrator.runBlocked"
        case .failed: "orchestrator.runFailed"
        case .interrupted: "orchestrator.runInterrupted"
        }
        return String(format: String(localized: key), count)
    }
}

/// A lane's dot: filled, or a ring for interrupted work (upstream `.dot`).
struct BoardLaneDot: View {
    let lane: RunLane
    let size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if lane == .interrupted {
                Circle().strokeBorder(theme[lane.token], lineWidth: max(1, size / 4))
            } else {
                Circle().fill(theme[lane.token])
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The agent a planner or worker runs on: its accent dot, or a chip glyph for none.
struct BoardAgentGlyph: View {
    let agent: String?
    let size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let agent, !agent.isEmpty {
                RoundedRectangle(cornerRadius: size / 4)
                    .fill(theme[AgentTokens.accent(for: agent)])
                    .frame(width: size * 0.7, height: size * 0.7)
                    .frame(width: size, height: size)
                    .help(Text(verbatim: String(format: String(localized: "orchestrator.agentTitle"), agent)))
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(theme[.textTertiary])
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small tinted label (context share, tokens, cost, worktree, diff).
struct BoardChip: View {
    let text: String
    var symbol: String?
    /// Already localized.
    var help: String?
    let units: BoardUnits
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: units.space(.xxs)) {
            if let symbol { Image(systemName: symbol) }
            Text(verbatim: text).monospacedDigit()
        }
        .font(units.font(.caption))
        .foregroundStyle(theme[.textSecondary])
        .padding(.horizontal, units.space(.xs))
        .padding(.vertical, units.size(1))
        .background(theme[.bgSunken], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
        .help(help ?? "")
    }
}
