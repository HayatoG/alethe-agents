import AletheAgents
import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// Home (upstream `HomeView`): greeting, quick launch, recent projects and actions, usage, activity,
/// time analytics and notifications — real data only. ⇧⌘H switches between Home and the workspace.
struct HomeView: View {
    let workspace: WorkspaceModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.space(.huge)) {
                VStack(alignment: .leading, spacing: metrics.space(.xxl)) {
                    HStack(alignment: .top, spacing: metrics.space(.xxl)) {
                        HomeHero()
                        Spacer(minLength: 0)
                        NowPlayingCard()
                    }
                    QuickLaunch(workspace: workspace)
                    SetupWalkthroughView(workspace: workspace)
                }
                .entrance(appeared, step: 0, reduced: environment.reducesMotion)
                HStack(alignment: .top, spacing: metrics.space(.xxl)) {
                    RecentProjects(workspace: workspace)
                    HomeActions()
                        .frame(width: metrics.size(240))
                }
                .entrance(appeared, step: 1, reduced: environment.reducesMotion)
                VStack(alignment: .leading, spacing: metrics.space(.huge)) {
                    UsageStrip()
                    ActivityGraph()
                    TimeAnalytics()
                    NotificationList()
                        .homeCard()
                    HomeFooter()
                }
                .entrance(appeared, step: 2, reduced: environment.reducesMotion)
            }
            .frame(maxWidth: metrics.size(960), alignment: .leading)
            .padding(metrics.space(.huge))
            .frame(maxWidth: .infinity)
        }
        .background(theme[.bg])
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home")
    }
}

// MARK: - Shared pieces

extension View {
    /// Home's staggered entrance: three steps at most, none under reduced motion.
    func entrance(_ appeared: Bool, step: Int, reduced: Bool) -> some View {
        opacity(appeared || reduced ? 1 : 0)
            .offset(y: appeared || reduced ? 0 : 8)
            .animation(reduced ? nil : .easeOut(duration: 0.28).delay(Double(step) * 0.06), value: appeared)
    }

    func homeCard() -> some View { modifier(HomeCard()) }
}

private struct HomeCard: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    func body(content: Content) -> some View {
        content
            .padding(metrics.space(.xl))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme[.surfaceCardDefault], in: RoundedRectangle(cornerRadius: metrics.radius(.lg)))
            .overlay(RoundedRectangle(cornerRadius: metrics.radius(.lg)).strokeBorder(theme[.borderSubtle]))
    }
}

struct HomeSectionHeader: View {
    let title: LocalizedStringKey
    var count: Int?
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.space(.s)) {
            Text(title).font(metrics.font(.headline))
            if let count {
                Text(verbatim: "\(count)").font(metrics.font(.caption).monospacedDigit()).foregroundStyle(theme[.textTertiary])
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

enum HomeFormat {
    static func duration(ms: UInt64) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes < 60 ? [.minutes] : [.hours, .minutes]
        return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: .narrow))
    }
}

// MARK: - Hero

private struct HomeHero: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: metrics.space(.xs)) {
                Text(verbatim: "\(greeting(context.date)), \(firstName).")
                    .font(metrics.font(.largeTitle))
                    .foregroundStyle(theme[.textPrimary])
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(metrics.font(.body))
                    .foregroundStyle(theme[.textTertiary])
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.greeting")
    }

    private var firstName: String {
        let full = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        return full.lowercased()
    }

    private func greeting(_ date: Date) -> String {
        switch Greeting(hour: Calendar.current.component(.hour, from: date)) {
        case .morning: String(localized: "home.greeting.morning")
        case .afternoon: String(localized: "home.greeting.afternoon")
        case .evening: String(localized: "home.greeting.evening")
        }
    }
}

// MARK: - Quick launch

/// The mini-terminal (upstream quick launch): a prompt, the agent, the project and the permission
/// mode; sending opens a new terminal of that agent in the project with the prompt as its first input.
private struct QuickLaunch: View {
    let workspace: WorkspaceModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.undoManager) private var undoManager
    @State private var prompt = ""
    @State private var agent: AgentKind = .claude
    @State private var projectID: ProjectID?
    @State private var unrestricted = false
    @FocusState private var focused: Bool

    private var agents: [AgentKind] {
        AgentRegistry.builtin.enabledKinds(environment.preferences?.document.enabledAgents).filter { $0 != .shell }
    }
    private var project: Project? {
        projectID.flatMap(workspace.document.project) ?? workspace.document.recentProjectIDs(limit: 1).first.flatMap(workspace.document.project)
    }
    private var descriptor: AgentDescriptor? { AgentRegistry.builtin.descriptor(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            HStack(spacing: metrics.space(.s)) {
                Text(verbatim: "›").font(metrics.monoFont(size: 15)).foregroundStyle(theme[.accent])
                TextField("home.quick.placeholder", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(metrics.monoFont(size: 14))
                    .lineLimit(1...(focused ? 6 : 1))
                    .focused($focused)
                    .onSubmit(send)
                    .accessibilityIdentifier("home.quick.prompt")
            }
            HStack(spacing: metrics.space(.m)) {
                Picker("home.quick.agent", selection: $agent) {
                    ForEach(agents, id: \.self) { Text(verbatim: AgentLabels.name(for: $0.rawValue)).tag($0) }
                }
                .fixedSize()
                .accessibilityIdentifier("home.quick.agent")
                Picker("home.quick.project", selection: Binding { project?.id } set: { projectID = $0 }) {
                    ForEach(workspace.document.projects) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                .accessibilityIdentifier("home.quick.project")
                if descriptor?.unrestrictedFlag != nil {
                    Picker("home.quick.mode", selection: $unrestricted) {
                        Text("home.quick.normal").tag(false)
                        Text("home.quick.unrestricted").tag(true)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("home.quick.mode")
                }
                Spacer()
                Button(action: send) { Label("home.quick.send", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(project == nil || agents.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("home.quick.send")
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .homeCard()
        .overlay(RoundedRectangle(cornerRadius: metrics.radius(.lg)).strokeBorder(focused ? theme[.accentBorder] : .clear))
        .onAppear {
            let last = AgentRegistry.builtin.parse(environment.preferences?.document.lastAgent)
            agent = last.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? .claude
            unrestricted = environment.preferences?.document.alwaysStartUnrestricted == true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.quick")
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project, !text.isEmpty, agents.contains(agent) else { return }
        let tab = PaneTab(agent: agent.rawValue, unrestricted: descriptor?.unrestrictedFlag != nil && unrestricted, initialPrompt: text)
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newTerminal")) {
            $0.openInTab(project.id)
            $0.addPane(to: project.id, tab: tab)
        }
        environment.preferences?.update { $0.lastAgent = agent.rawValue }
        prompt = ""
        environment.showingHome = false
    }
}

// MARK: - Recent projects and actions

private struct RecentProjects: View {
    let workspace: WorkspaceModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        let recent = workspace.document.recentProjectIDs().compactMap(workspace.document.project)
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            HomeSectionHeader(title: "home.recent", count: recent.isEmpty ? nil : recent.count)
            if recent.isEmpty {
                VStack(alignment: .leading, spacing: metrics.space(.s)) {
                    Text("home.recent.empty").foregroundStyle(theme[.textSecondary])
                    Button("home.recent.create") { environment.editorRequest = .newProject(.ungrouped) }
                }
                .homeCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.size(200)), spacing: metrics.space(.m))],
                          spacing: metrics.space(.m)) {
                    ForEach(recent) { project in card(project) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ project: Project) -> some View {
        let terminals = project.panes.filter { $0.content.isTerminal }.count
        return Button {
            workspace.update { $0.openInTab(project.id) }
            environment.showingHome = false
        } label: {
            HStack(spacing: metrics.space(.m)) {
                Text(verbatim: String(project.name.trimmingCharacters(in: .whitespaces).first ?? "·").uppercased())
                    .font(metrics.font(.headline))
                    .foregroundStyle(theme[.accentOn])
                    .frame(width: metrics.size(28), height: metrics.size(28))
                    .background(theme[project.color.token], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
                VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                    Text(verbatim: project.name).font(metrics.font(.body).weight(.medium)).lineLimit(1)
                    Text(String(format: String(localized: "home.recent.terminals"), terminals))
                        .font(metrics.font(.footnote)).foregroundStyle(theme[.textTertiary])
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").foregroundStyle(theme[.textTertiary])
            }
            .contentShape(Rectangle())
            .homeCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.recent.\(project.name)")
    }
}

private struct HomeActions: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            HomeSectionHeader(title: "home.start")
            VStack(spacing: metrics.space(.xs)) {
                row("home.action.newTerminal", icon: "terminal", keys: "⌘T", id: "home.action.newTerminal") {
                    environment.editorRequest = .newTerminal(nil)
                }
                row("home.action.newProject", icon: "folder.badge.plus", keys: "⌘N", id: "home.action.newProject") {
                    environment.editorRequest = .newProject(.ungrouped)
                }
                row("home.action.newGroup", icon: "square.stack.3d.up", keys: nil, id: "home.action.newGroup") {
                    environment.editorRequest = .newGroup(parent: nil)
                }
                row("home.action.findJump", icon: "magnifyingglass", keys: "⌘K", id: "home.action.findJump") {
                    environment.editorRequest = .findJump
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, icon: String, keys: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: metrics.space(.m)) {
                Image(systemName: icon).frame(width: metrics.size(18)).foregroundStyle(theme[.textSecondary])
                Text(title)
                Spacer()
                if let keys { Text(verbatim: keys).font(metrics.font(.footnote)).foregroundStyle(theme[.textTertiary]) }
            }
            .padding(.horizontal, metrics.space(.l))
            .padding(.vertical, metrics.space(.m))
            .contentShape(Rectangle())
            .background(theme[.surfaceCardDefault], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Footer

private struct HomeFooter: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    private static let repository = URL(string: "https://github.com/Kc1t/alethe-agents")!

    var body: some View {
        HStack(spacing: metrics.space(.xl)) {
            Link(destination: Self.repository) { Label("home.repository", systemImage: "chevron.left.forwardslash.chevron.right") }
            Link(destination: Self.repository.appending(path: "issues")) { Label("home.issues", systemImage: "smallcircle.filled.circle") }
            Link(destination: Self.repository.appending(path: "releases")) { Label("home.releases", systemImage: "shippingbox") }
        }
        .font(metrics.font(.footnote))
        .foregroundStyle(theme[.textTertiary])
    }
}

/// Toolbar: Home ↔ workspace.
struct HomeButton: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button { environment.showingHome.toggle() } label: {
            // One glyph with a variant plus a minimum frame: swapping symbols let the macOS 27
            // toolbar propose 0×0 to the new glyph mid-relayout (seen while screen recording),
            // and CoreUI throws when asked to rasterize a symbol at that size.
            Image(systemName: "house")
                .symbolVariant(environment.showingHome ? .fill : .none)
                .frame(minWidth: 16, minHeight: 16)
        }
        .help(Text(environment.showingHome ? "menu.view.showWorkspace" : "menu.view.showHome"))
        .accessibilityLabel(Text("menu.view.showHome"))
        .accessibilityValue(Text(environment.showingHome ? "home.shown" : "home.hidden"))
        .accessibilityIdentifier("home.button")
    }
}
