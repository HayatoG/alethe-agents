import AletheDesign
import AletheIntegrations
import AletheModel
import AlethePluginKit
import SwiftUI

/// Where the MCP manager opens.
struct McpManagerRoute: Hashable {
    enum Tab: String, Hashable { case servers, skills }

    var tab = Tab.servers
    var server: String?
    var add = false
}

/// The right sidebar's MCP tab (upstream `McpPanel`, EXT-1): servers grouped by name across agents,
/// with scope switch, agent filter, live health and config diagnostics; or the skills of every agent.
/// Rows open the MCP manager, where every change happens.
struct McpPanel: View {
    @Environment(AppEnvironment.self) private var environment

    static let tabID = "mcp"
    static let tab = SidebarTabContribution(id: tabID, title: "MCP", symbol: "powerplug", side: .right, viewID: tabID)

    var body: some View {
        if let model = environment.mcp {
            McpPanelContent(model: model, skillStore: environment.skillStore, folder: selectedFolder)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedFolder: String? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)?.folder
        }
    }
}

private struct McpPanelContent: View {
    enum Section: String, Hashable { case servers, skills }

    let model: McpManagerModel
    let skillStore: SkillStore
    let folder: String?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var section = Section.servers
    @State private var query = ""
    @State private var picked: Set<McpAgent> = []
    @State private var skills: [SkillGroup]?

    private var visibleServers: [McpServerGroup] {
        model.groups.filter { $0.matches(query) && $0.isOn(anyOf: picked) }
    }

    private var visibleSkills: [SkillGroup] {
        (skills ?? []).filter { group in
            group.matches(query) && (picked.isEmpty || group.agents.contains { agent in
                picked.contains { $0.rawValue == agent.rawValue }
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            header
            TextField(text: $query, prompt: Text((section == .servers ? "mcp.search" : "mcp.searchSkills") as LocalizedStringKey)) {
                Text("mcp.search")
            }
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("mcp.panel.search")
            filters
            stats
            if section == .servers, let error = model.error {
                banner(error, symbol: "exclamationmark.triangle.fill", token: .statusStopped, id: "mcp.panel.error")
            }
            list
            addButton
            if section == .servers, !model.issues.isEmpty { diagnostics }
        }
        .padding(metrics.space(.l))
        .task(id: folder) { model.setRepository(folder) }
        .task(id: section) {
            if section == .skills, skills == nil { await loadSkills() }
        }
        .onChange(of: model.groups) { model.checkHealthOnce() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp.panel")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: metrics.space(.s)) {
            Picker("mcp.view", selection: $section) {
                Text("mcp.tab.servers").tag(Section.servers)
                Text("mcp.tab.skills").tag(Section.skills)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("mcp.panel.section")
            Spacer(minLength: 0)
            if section == .servers, model.healthAvailable {
                Button {
                    model.checkAllHealth()
                } label: {
                    Image(systemName: model.checking.isEmpty ? "waveform.path.ecg" : "hourglass")
                }
                .buttonStyle(.borderless)
                .disabled(!model.checking.isEmpty || model.groups.isEmpty)
                .help(Text("mcp.health.checkAll"))
                .accessibilityLabel(Text("mcp.health.checkAll"))
                .accessibilityIdentifier("mcp.panel.health")
            }
            Button {
                if section == .servers { Task { await model.refresh() } } else { Task { await loadSkills() } }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.loading)
            .help(Text("mcp.refresh"))
            .accessibilityLabel(Text("mcp.refresh"))
            .accessibilityIdentifier("mcp.panel.refresh")
        }
    }

    private var filters: some View {
        HStack(spacing: metrics.space(.xs)) {
            ForEach(McpAgent.allCases, id: \.self) { agent in
                let on = picked.contains(agent)
                Button {
                    if on { picked.remove(agent) } else { picked.insert(agent) }
                } label: {
                    Circle()
                        .fill(theme[agent.colorToken].opacity(on || picked.isEmpty ? 1 : 0.3))
                        .frame(width: metrics.size(10), height: metrics.size(10))
                        .padding(metrics.space(.xs))
                        .background(on ? theme[.accentBgSoft] : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: agent.label))
                .accessibilityLabel(Text(verbatim: agent.label))
                .accessibilityValue(Text((on ? "mcp.filter.on" : "mcp.filter.off") as LocalizedStringKey))
                .accessibilityIdentifier("mcp.panel.agent.\(agent.rawValue)")
            }
            Spacer(minLength: metrics.space(.s))
            if section == .servers {
                Picker("mcp.scope", selection: scope) {
                    Text("mcp.scope.project").tag(McpScope.project)
                    Text("mcp.scope.global").tag(McpScope.global)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(folder == nil)
                .help(Text((folder == nil ? "mcp.scope.projectUnavailable" : "mcp.scope.help") as LocalizedStringKey))
                .accessibilityIdentifier("mcp.panel.scope")
            }
        }
    }

    private var scope: Binding<McpScope> {
        Binding { model.effectiveScope } set: { model.setScope($0) }
    }

    private var stats: some View {
        let shown = section == .servers ? visibleServers.count : visibleSkills.count
        let total = section == .servers ? model.groups.count : (skills?.count ?? 0)
        let filtered = !picked.isEmpty || !query.trimmingCharacters(in: .whitespaces).isEmpty
        let text = section == .servers
            ? (filtered ? format("mcp.stats.serversOf", shown, total) : format("mcp.stats.servers", shown))
            : (filtered ? format("mcp.stats.skillsOf", shown, total) : format("mcp.stats.skills", shown))
        return Text(verbatim: text)
            .font(metrics.font(.caption))
            .foregroundStyle(theme[.textSecondary])
            .accessibilityIdentifier("mcp.panel.stats")
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let loaded = section == .servers ? model.snapshots != nil : skills != nil
        let empty = section == .servers ? visibleServers.isEmpty : visibleSkills.isEmpty
        let none = section == .servers ? model.groups.isEmpty : (skills ?? []).isEmpty
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if empty {
            ContentUnavailableView {
                Label(emptyTitle(none: none), systemImage: "powerplug")
            } description: {
                if none && section == .servers { Text("mcp.empty.detail") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("mcp.panel.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.space(.xs)) {
                    if section == .servers {
                        ForEach(visibleServers, id: \.name) { group in serverRow(group) }
                    } else {
                        ForEach(visibleSkills) { group in skillRow(group) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func emptyTitle(none: Bool) -> LocalizedStringKey {
        guard none else { return "mcp.noMatch" }
        return section == .servers ? "mcp.empty.title" : "skills.empty.title"
    }

    private func serverRow(_ group: McpServerGroup) -> some View {
        Button {
            environment.editorRequest = .mcpManager(McpManagerRoute(server: group.name))
        } label: {
            VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                HStack(spacing: metrics.space(.xs)) {
                    if let status = model.status(of: group) {
                        McpHealthDot(status: status)
                    }
                    Text(verbatim: group.name)
                        .font(metrics.font(.body).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if group.hasDisabled { McpBadge(title: "mcp.badge.disabled") }
                    if group.records.contains(where: { $0.managedByImport != nil }) {
                        McpBadge(title: "mcp.badge.imported", token: .statusWaiting)
                    }
                    Spacer(minLength: 0)
                    McpAgentDots(present: group.agents, missing: group.missingAgents)
                }
                Text(verbatim: group.records.first?.server.transport.summary ?? "")
                    .font(metrics.font(.caption).monospaced())
                    .foregroundStyle(theme[.textSecondary])
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(metrics.space(.s))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme[.surfaceCardDefault], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: presence(group)))
        .accessibilityIdentifier("mcp.panel.row.\(group.name)")
    }

    private func presence(_ group: McpServerGroup) -> String {
        var text = format("mcp.presentOn", McpManagerModel.labels(group.agents))
        if !group.missingAgents.isEmpty { text += " · " + format("mcp.missingOn", McpManagerModel.labels(group.missingAgents)) }
        return text
    }

    private func skillRow(_ group: SkillGroup) -> some View {
        Button {
            environment.editorRequest = .mcpManager(McpManagerRoute(tab: .skills))
        } label: {
            VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                HStack(spacing: metrics.space(.xs)) {
                    Text(verbatim: group.name)
                        .font(metrics.font(.body).weight(.medium))
                        .lineLimit(1)
                    if group.bundled {
                        Image(systemName: "lock.fill").foregroundStyle(theme[.textTertiary])
                            .accessibilityLabel(Text("skills.badge.bundled"))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: metrics.space(.xxs)) {
                        ForEach(group.agents, id: \.self) { agent in
                            Circle().fill(theme[agent.colorToken]).frame(width: metrics.size(7), height: metrics.size(7))
                        }
                    }
                }
                Text(verbatim: group.description.isEmpty ? group.agents.map(\.label).joined(separator: ", ") : group.description)
                    .font(metrics.font(.caption))
                    .foregroundStyle(theme[.textSecondary])
                    .lineLimit(2)
            }
            .padding(metrics.space(.s))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme[.surfaceCardDefault], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mcp.panel.skill.\(group.name)")
    }

    private var addButton: some View {
        Button {
            environment.editorRequest = .mcpManager(section == .servers ? McpManagerRoute(add: true) : McpManagerRoute(tab: .skills))
        } label: {
            Label((section == .servers ? "mcp.addServer" : "mcp.manageSkills") as LocalizedStringKey,
                  systemImage: section == .servers ? "plus" : "wand.and.stars")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(section == .servers && model.writableAgents.isEmpty)
        .accessibilityIdentifier("mcp.panel.add")
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
            Text("mcp.diag.title")
                .font(metrics.font(.caption).weight(.semibold))
                .foregroundStyle(theme[.textSecondary])
                .textCase(.uppercase)
            ForEach(model.issues, id: \.agent) { item in
                HStack(alignment: .firstTextBaseline, spacing: metrics.space(.xs)) {
                    Text(verbatim: item.agent.label)
                        .font(metrics.font(.caption).weight(.medium))
                    Text(item.issue.title)
                        .font(metrics.font(.caption))
                        .foregroundStyle(theme[.textSecondary])
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mcp.panel.diagnostics")
    }

    private func banner(_ text: String, symbol: String, token: ThemeToken, id: String) -> some View {
        Label { Text(verbatim: text).textSelection(.enabled) } icon: { Image(systemName: symbol) }
            .font(metrics.font(.footnote))
            .foregroundStyle(theme[token])
            .accessibilityIdentifier(id)
    }

    private func loadSkills() async {
        let snapshots = (try? await skillStore.scan()) ?? []
        skills = SkillGroup.group(snapshots)
    }
}

// MARK: - Shared pieces

extension McpSnapshotIssue {
    var title: LocalizedStringKey {
        switch self {
        case .unsupported: "mcp.diag.unsupported"
        case .unreadable: "mcp.diag.unreadable"
        case .missing: "mcp.diag.missing"
        case .readOnly: "mcp.diag.readOnly"
        }
    }
}

extension McpHealthStatus {
    var title: LocalizedStringKey {
        switch self {
        case .connected: "mcp.health.connected"
        case .failed: "mcp.health.failed"
        case .needsAuth: "mcp.health.needsAuth"
        case .disabled: "mcp.health.disabled"
        case .unknown: "mcp.health.unknown"
        }
    }

    var token: ThemeToken {
        switch self {
        case .connected: .statusActive
        case .failed: .statusStopped
        case .needsAuth: .statusWaiting
        case .disabled, .unknown: .statusIdle
        }
    }
}

struct McpHealthDot: View {
    let status: McpHealthStatus
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        Circle()
            .fill(theme[status.token])
            .frame(width: metrics.size(7), height: metrics.size(7))
            .help(Text(status.title))
            .accessibilityLabel(Text(status.title))
    }
}

struct McpBadge: View {
    let title: LocalizedStringKey
    var token: ThemeToken = .textSecondary
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        Text(title)
            .font(metrics.font(.caption))
            .foregroundStyle(theme[token])
            .padding(.horizontal, metrics.space(.xs))
            .padding(.vertical, metrics.space(.xxs))
            .background(theme[.bgSunken], in: Capsule())
    }
}

/// Agents that have the server (filled) and readable agents that lack it (hollow).
struct McpAgentDots: View {
    let present: [McpAgent]
    let missing: [McpAgent]
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.space(.xxs)) {
            ForEach(McpAgent.allCases.filter { present.contains($0) || missing.contains($0) }, id: \.self) { agent in
                if present.contains(agent) {
                    Circle().fill(theme[agent.colorToken])
                        .frame(width: metrics.size(7), height: metrics.size(7))
                } else {
                    Circle().strokeBorder(theme[agent.colorToken], lineWidth: 1)
                        .frame(width: metrics.size(7), height: metrics.size(7))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
