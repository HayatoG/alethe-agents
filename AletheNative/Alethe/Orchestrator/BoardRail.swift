import AletheDesign
import AletheOrchestrator
import SwiftUI

/// The planner tab strip (upstream `PlannerTab`): one tab per planner with its agent, name and run
/// count, or what needs the person when it is not the open one; a closed planner tab says so.
struct BoardPlannerTabs: View {
    let board: OrchestratorBoardModel
    let label: (PlannerGroup) -> String?
    let isGone: (PlannerGroup) -> Bool
    let onAddPlanner: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: metrics.space(.xs)) {
                    ForEach(board.groups, id: \.id) { group in
                        tab(group)
                    }
                }
                .padding(.horizontal, metrics.space(.s))
            }
            .scrollIndicators(.never)
            Button(action: onAddPlanner) {
                Image(systemName: "plus")
                    .font(metrics.font(.caption).weight(.semibold))
                    .frame(width: metrics.size(22), height: metrics.size(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme[.textTertiary])
            .help(Text("orchestrator.addPlannerTitle"))
            .accessibilityLabel(Text("orchestrator.addPlannerTitle"))
            .accessibilityIdentifier("orchestrator.addPlanner")
            .padding(.trailing, metrics.space(.s))
        }
        .frame(height: metrics.size(32))
        .background(theme[.bg])
        .overlay(alignment: .bottom) { Rectangle().fill(theme[.borderSubtle]).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.tabs")
    }

    private func tab(_ group: PlannerGroup) -> some View {
        let key = BoardData.key(group)
        let selected = key == board.activeKey
        let gone = isGone(group)
        let alert = selected ? nil : group.counts.attention
        let name = label(group)
        return Button { board.openPlanner(key) } label: {
            HStack(spacing: metrics.space(.xs)) {
                BoardAgentGlyph(agent: group.agent, size: metrics.size(13))
                BoardLaneDot(lane: group.state, size: metrics.size(6))
                Group {
                    if let name { Text(verbatim: name) } else { Text("orchestrator.noPlanner") }
                }
                .font(metrics.font(.footnote).weight(selected ? .semibold : .regular))
                .foregroundStyle(theme[gone ? .textTertiary : selected ? .textPrimary : .textSecondary])
                .strikethrough(gone, color: theme[.textTertiary])
                .lineLimit(1)
                if gone {
                    Text("orchestrator.plannerClosed")
                        .font(metrics.font(.caption))
                        .foregroundStyle(theme[.textTertiary])
                }
                if let alert {
                    Text(verbatim: alert.text)
                        .font(metrics.font(.caption).weight(.semibold))
                        .foregroundStyle(theme[alert.lane == .blocked ? .bg : alert.lane.runLane.token])
                        .padding(.horizontal, metrics.space(.xs))
                        .background(theme[alert.lane == .blocked ? .statusWaiting : .bgSunken],
                                    in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
                } else {
                    Text(verbatim: String(format: String(localized: "orchestrator.runCount"), group.runs.count))
                        .font(metrics.font(.caption))
                        .monospacedDigit()
                        .foregroundStyle(theme[.textTertiary])
                }
            }
            .padding(.horizontal, metrics.space(.m))
            .frame(height: metrics.size(24))
            .background(theme[selected ? .surfaceCardSelected : .bg], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: tabHelp(group, name: name, gone: gone)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("orchestrator.tab.\(key.isEmpty ? "none" : key)")
    }

    private func tabHelp(_ group: PlannerGroup, name: String?, gone: Bool) -> String {
        guard let name else { return String(localized: "orchestrator.noPlannerTitle") }
        if gone { return String(localized: "orchestrator.plannerGone") }
        guard let agent = group.agent else { return name }
        return String(format: String(localized: "orchestrator.plannerTitle"), name, agent)
    }
}

/// The summary rail (upstream `rail`): what the open planner has finished, every lane's count and
/// the slots in use, its runs with their workers (the ones needing the person first, finished runs
/// folded), and the other planners that need the person.
struct BoardRail: View {
    let board: OrchestratorBoardModel
    let snapshot: OrchestratorSnapshot
    let plannerName: String?
    let label: (PlannerGroup) -> String?
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { board.summaryOpen.toggle() } label: {
                HStack(spacing: metrics.space(.s)) {
                    Image(systemName: board.summaryOpen ? "chevron.right" : "chevron.left")
                        .font(metrics.font(.caption).weight(.semibold))
                    if board.summaryOpen {
                        Text("orchestrator.summary")
                            .textCase(.uppercase)
                            .font(metrics.font(.caption).weight(.semibold))
                        Group {
                            if let plannerName { Text(verbatim: plannerName) } else { Text("orchestrator.noPlanner") }
                        }
                        .font(metrics.font(.caption))
                        .foregroundStyle(theme[.textTertiary])
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(theme[.textSecondary])
                .padding(.horizontal, metrics.space(.m))
                .frame(height: metrics.size(28))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(board.summaryOpen ? LocalizedStringKey("orchestrator.summaryCollapse") : "orchestrator.summaryExpand"))
            .accessibilityIdentifier("orchestrator.rail.toggle")
            if board.summaryOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.space(.l)) {
                        headline
                        lanes
                        runs
                        attention
                    }
                    .padding(metrics.space(.m))
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: board.summaryOpen ? metrics.size(248) : metrics.size(30))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme[.bg])
        .overlay(alignment: .leading) { Rectangle().fill(theme[.borderSubtle]).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.rail")
    }

    private var counts: RunCounts { board.activeGroup?.counts ?? RunCounts() }

    private var headline: some View {
        let total = board.activeGroup?.jobs.count ?? 0
        let finished = counts[.finished]
        let percent = total == 0 ? 0 : Int((Double(finished) / Double(total) * 100).rounded())
        return HStack(alignment: .firstTextBaseline, spacing: metrics.space(.s)) {
            Text(verbatim: "\(finished)")
                .font(metrics.font(.title2))
                .monospacedDigit()
                .foregroundStyle(theme[.textPrimary])
            Text(verbatim: String(format: String(localized: "orchestrator.finishedHeadline"), total))
                .font(metrics.font(.footnote))
                .foregroundStyle(theme[.textSecondary])
            Spacer(minLength: 0)
            Text(verbatim: String(format: String(localized: "orchestrator.percent"), percent))
                .font(metrics.font(.footnote))
                .monospacedDigit()
                .foregroundStyle(theme[.textTertiary])
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestrator.rail.headline")
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: metrics.space(.xs)) {
            ForEach(RunLane.allCases, id: \.self) { lane in
                HStack(spacing: metrics.space(.s)) {
                    BoardLaneDot(lane: lane, size: metrics.size(6))
                    Text(lane.title).foregroundStyle(theme[.textSecondary])
                    Spacer(minLength: 0)
                    Text(verbatim: "\(counts[lane])").monospacedDigit().foregroundStyle(theme[.textPrimary])
                }
                .opacity(counts[lane] == 0 ? 0.5 : 1)
                .help(lane.explanation.map { Text($0) } ?? Text(verbatim: ""))
            }
            HStack(spacing: metrics.space(.s)) {
                Circle().strokeBorder(theme[.accent], lineWidth: 1).frame(width: metrics.size(6), height: metrics.size(6))
                Text("orchestrator.slots").foregroundStyle(theme[.textSecondary])
                Spacer(minLength: 0)
                Text(verbatim: "\(snapshot.running)/\(snapshot.concurrencyLimit)")
                    .monospacedDigit()
                    .foregroundStyle(theme[.textPrimary])
            }
        }
        .font(metrics.font(.footnote))
    }

    private var runs: some View {
        let runs = BoardData.railRuns(board.activeGroup?.runs ?? [])
        return VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
            sectionLabel("orchestrator.runsLabel", count: runs.count)
            if runs.isEmpty {
                Text("orchestrator.noWorkers")
                    .font(metrics.font(.footnote))
                    .foregroundStyle(theme[.textTertiary])
            }
            ForEach(runs) { run in
                runBranch(run)
            }
        }
    }

    private func runBranch(_ run: BoardRun) -> some View {
        let open = board.isRunOpen(run)
        return VStack(alignment: .leading, spacing: 0) {
            Button { board.toggleRun(run) } label: {
                HStack(spacing: metrics.space(.s)) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(metrics.font(.caption).weight(.semibold))
                        .foregroundStyle(theme[.textTertiary])
                        .frame(width: metrics.size(10))
                    BoardLaneDot(lane: run.state, size: metrics.size(6))
                    Text(verbatim: run.label)
                        .foregroundStyle(theme[.textPrimary])
                        .lineLimit(1)
                    Text(verbatim: "\(run.jobs.count)")
                        .monospacedDigit()
                        .foregroundStyle(theme[.textTertiary])
                    Spacer(minLength: 0)
                    Text(run.state.title)
                        .font(metrics.font(.caption))
                        .foregroundStyle(theme[run.state == .finished || run.state == .queued ? .textTertiary : run.state.token])
                        .lineLimit(1)
                }
                .font(metrics.font(.footnote))
                .padding(.vertical, metrics.space(.xs))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(run.state.explanation.map { Text($0) } ?? Text("orchestrator.selectRun"))
            .accessibilityValue(Text(open ? LocalizedStringKey("orchestrator.rail.open") : "orchestrator.rail.closed"))
            .accessibilityIdentifier("orchestrator.rail.run.\(run.id)")
            if open {
                ForEach(run.jobs) { job in
                    workerRow(job)
                }
            }
        }
    }

    private func workerRow(_ job: JobSnapshot) -> some View {
        let lane = RunLane(job.status)
        let selected = board.selectedWorker == job.id
        let elapsed = BoardFormat.elapsed(board.elapsed(job))
        return Button { board.reveal(worker: job.id) } label: {
            HStack(spacing: metrics.space(.s)) {
                BoardLaneDot(lane: lane, size: metrics.size(6))
                BoardAgentGlyph(agent: job.agent, size: metrics.size(12))
                Text(verbatim: job.id)
                    .font(metrics.font(.footnote).monospaced())
                    .foregroundStyle(theme[selected ? .textPrimary : .textSecondary])
                    .lineLimit(1)
                Spacer(minLength: 0)
                // A blocked worker's clock still runs, but the state is what the row has to report.
                Group {
                    if lane == .blocked || elapsed == nil { Text(lane.title) } else { Text(verbatim: elapsed ?? "") }
                }
                .font(metrics.font(.caption))
                .monospacedDigit()
                .foregroundStyle(theme[lane == .finished || lane == .queued ? .textTertiary : lane.token])
            }
            .padding(.leading, metrics.space(.xl))
            .padding(.trailing, metrics.space(.xs))
            .padding(.vertical, metrics.space(.xs))
            .background(theme[selected ? .surfaceCardSelected : .bg], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(lane.explanation.map { Text($0) } ?? Text("orchestrator.selectWorker"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("orchestrator.rail.worker.\(job.id)")
    }

    @ViewBuilder private var attention: some View {
        let rows = board.groups.compactMap { group -> (PlannerGroup, RunAttention)? in
            guard BoardData.key(group) != board.activeKey, let attention = group.counts.attention else { return nil }
            return (group, attention)
        }
        // Blocked first: a failure is already over, a blocked worker still holds its slot.
        .sorted { ($0.1.lane == .blocked ? 0 : 1) < ($1.1.lane == .blocked ? 0 : 1) }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                sectionLabel("orchestrator.attentionLabel", count: nil)
                ForEach(rows, id: \.0.id) { group, attention in
                    Button { board.openPlanner(BoardData.key(group)) } label: {
                        HStack(spacing: metrics.space(.s)) {
                            BoardAgentGlyph(agent: group.agent, size: metrics.size(12))
                            Group {
                                if let name = label(group) { Text(verbatim: name) } else { Text("orchestrator.noPlanner") }
                            }
                            .foregroundStyle(theme[.textPrimary])
                            .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(verbatim: attention.text)
                                .foregroundStyle(theme[attention.lane.runLane.token])
                        }
                        .font(metrics.font(.footnote))
                        .padding(.vertical, metrics.space(.xs))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(attention.lane.runLane.explanation.map { Text($0) } ?? Text(verbatim: ""))
                    .accessibilityIdentifier("orchestrator.attention.\(BoardData.key(group).isEmpty ? "none" : BoardData.key(group))")
                }
            }
        }
    }

    private func sectionLabel(_ key: LocalizedStringKey, count: Int?) -> some View {
        HStack(spacing: metrics.space(.s)) {
            Text(key).textCase(.uppercase)
            if let count { Text(verbatim: "\(count)").monospacedDigit() }
        }
        .font(metrics.font(.caption).weight(.semibold))
        .foregroundStyle(theme[.textTertiary])
        .padding(.bottom, metrics.space(.xxs))
    }
}
