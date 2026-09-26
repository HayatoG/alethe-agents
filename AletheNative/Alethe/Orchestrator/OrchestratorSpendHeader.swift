import AletheDesign
import AletheOrchestrator
import SwiftUI

/// The board header's spend per agent for the selected planner (upstream `aggregateAgentSpend`:
/// cost, or "no price" when no worker of that agent is priced) and a warning chip per agent at the
/// headroom threshold or rate-limited, with its reset (upstream `useOrchestratorQuotaWarnings`).
/// While it is on screen the board counts as open for the usage feed.
struct OrchestratorSpendHeader: View {
    let jobs: [JobSnapshot]
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var board = UUID()

    private var feed: OrchestratorQuotaFeed { .shared }

    var body: some View {
        HStack(spacing: metrics.space(.s)) {
            ForEach(AgentSpend.aggregate(jobs), id: \.agent) { spendChip($0) }
            if !feed.warnings.isEmpty {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: metrics.space(.s)) {
                        ForEach(feed.warnings, id: \.agent) { quotaChip($0, now: context.date) }
                    }
                }
            }
        }
        .font(metrics.font(.caption))
        .lineLimit(1)
        .onAppear { feed.open(board, environment: environment) }
        .onDisappear { feed.close(board) }
    }

    private func spendChip(_ spend: AgentSpend) -> some View {
        let price = spend.pricedWorkers > 0 ? SessionCostView.dollars(spend.costUSD) : String(localized: "orchestrator.noPrice")
        let tokens = SessionCostView.tokens(Int(spend.totalTokens))
        let name = AgentLabels.name(for: spend.agent)
        return HStack(spacing: metrics.space(.xs)) {
            BoardAgentGlyph(agent: spend.agent, size: metrics.size(11))
            Text(verbatim: name).foregroundStyle(theme[.fgMuted])
            Text(verbatim: price).fontWeight(.semibold).foregroundStyle(theme[.fg])
        }
        .monospacedDigit()
        .padding(.horizontal, metrics.space(.xs))
        .background(theme[.panel], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
        .overlay(RoundedRectangle(cornerRadius: metrics.radius(.sm)).strokeBorder(theme[.border]))
        .help(Text(verbatim: String(format: String(localized: "orchestrator.agentSpendTitle"), name, price, tokens)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestrator.spend.\(spend.agent)")
    }

    private func quotaChip(_ warning: QuotaWarning, now: Date) -> some View {
        let name = AgentLabels.name(for: warning.agent)
        let resets = warning.resetsAt.map { QuotaWarning.countdown(to: $0, now: now) ?? String(localized: "orchestrator.quotaResetsNow") } ?? "—"
        let title = warning.rateLimited
            ? String(format: String(localized: "orchestrator.quotaRateLimitedTitle"), name)
            : String(format: String(localized: "orchestrator.quotaWarningTitle"), name, warning.used)
        return Text(verbatim: String(format: String(localized: "orchestrator.quotaWarning"), name, warning.used, resets))
            .monospacedDigit()
            .foregroundStyle(theme[.statusWaiting])
            .padding(.horizontal, metrics.space(.xs))
            .background(theme[.statusWaitingSoft], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
            .help(Text(verbatim: title))
            .accessibilityIdentifier("orchestrator.quota.\(warning.agent)")
    }
}
