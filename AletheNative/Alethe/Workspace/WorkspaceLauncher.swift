import AletheAgents
import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// What the workspace shows when nothing is open (upstream `WorkspaceEmptyState` and the "no project"
/// card): quick actions with their shortcuts, or — before the first project exists — an agent
/// picker that opens a folder as a project and starts a terminal in it.
struct WorkspaceLauncher: View {
    let workspace: WorkspaceModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.undoManager) private var undoManager
    @State private var agent: AgentKind = .claude

    private var document: WorkspaceDocument { workspace.document }
    private var agents: [AgentKind] { AgentRegistry.builtin.enabledKinds(environment.preferences?.document.enabledAgents) }

    var body: some View {
        VStack(spacing: metrics.space(.xxl)) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: metrics.size(64), height: metrics.size(64))
                .accessibilityHidden(true)
            if document.projects.isEmpty {
                firstProject
            } else {
                actions
            }
        }
        .frame(maxWidth: metrics.size(440))
        .padding(metrics.space(.xxxl))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.empty")
        .onAppear {
            let last = AgentRegistry.builtin.parse(environment.preferences?.document.lastAgent)
            agent = last.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? .shell
        }
    }

    // MARK: - Quick actions

    private var actions: some View {
        VStack(spacing: metrics.space(.xs)) {
            if let project = document.workspace.selectedProjectID.flatMap(document.project) ?? document.projects.first {
                row(Text(String(format: String(localized: "launcher.open"), project.name)), keys: [], id: "launcher.open") {
                    workspace.update { $0.openInTab(project.id) }
                }
            }
            row(Text("menu.file.newTerminal"), keys: ["⌘", "T"], id: "launcher.newTerminal") {
                environment.editorRequest = .newTerminal(nil)
            }
            row(Text("menu.file.newProject"), keys: ["⌘", "N"], id: "launcher.newProject") {
                environment.editorRequest = .newProject(.ungrouped)
            }
            if !AddContentSheet.options.isEmpty {
                row(Text("menu.file.addContent"), keys: ["⇧", "⌘", "A"], id: "launcher.addContent") {
                    environment.editorRequest = .addContent(nil)
                }
            }
            if !document.workspace.closedTabs.isEmpty {
                row(Text("menu.history.reopenTab"), keys: ["⇧", "⌘", "T"], id: "launcher.reopenTab") {
                    workspace.update { $0.reopenClosedWorkspaceTab() }
                }
            }
        }
    }

    private func row(_ title: Text, keys: [String], id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: metrics.space(.m)) {
                title
                    .font(metrics.font(.body))
                    .foregroundStyle(theme[.textPrimary])
                    .lineLimit(1)
                Spacer(minLength: metrics.space(.l))
                HStack(spacing: metrics.space(.xxs)) {
                    ForEach(keys, id: \.self) { key in
                        Text(verbatim: key)
                            .font(metrics.font(.footnote).monospaced())
                            .foregroundStyle(theme[.textSecondary])
                            .frame(minWidth: metrics.size(18), minHeight: metrics.size(18))
                            .background(theme[.bgSunken], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
                            .overlay(RoundedRectangle(cornerRadius: metrics.radius(.sm)).strokeBorder(theme[.borderSubtle]))
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, metrics.space(.l))
            .padding(.vertical, metrics.space(.m))
            .background(theme[.panel], in: RoundedRectangle(cornerRadius: metrics.radius(.md)))
            .overlay(RoundedRectangle(cornerRadius: metrics.radius(.md)).strokeBorder(theme[.borderSubtle]))
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherButtonStyle())
        .accessibilityIdentifier(id)
    }

    // MARK: - First project

    private var firstProject: some View {
        VStack(spacing: metrics.space(.l)) {
            VStack(spacing: metrics.space(.xs)) {
                Text("workspace.empty.title")
                    .font(metrics.font(.title2))
                    .foregroundStyle(theme[.textPrimary])
                Text("launcher.firstProject.message")
                    .font(metrics.font(.body))
                    .foregroundStyle(theme[.textSecondary])
                    .multilineTextAlignment(.center)
            }
            Text("launcher.startWith")
                .font(metrics.font(.footnote).weight(.semibold))
                .foregroundStyle(theme[.textTertiary])
            HStack(spacing: metrics.space(.s)) {
                ForEach(agents, id: \.self) { kind in
                    let selected = kind == agent
                    Button { agent = kind } label: {
                        HStack(spacing: metrics.space(.xs)) {
                            Circle()
                                .fill(theme[AgentTokens.accent(for: kind.rawValue)])
                                .frame(width: metrics.size(8), height: metrics.size(8))
                            Text(verbatim: AgentLabels.name(for: kind.rawValue))
                                .font(metrics.font(.footnote).weight(selected ? .semibold : .regular))
                        }
                        .padding(.horizontal, metrics.space(.m))
                        .padding(.vertical, metrics.space(.s))
                        .background(theme[selected ? .surfaceCardSelected : .panel], in: Capsule())
                        .overlay(Capsule().strokeBorder(theme[selected ? .accent : .borderSubtle]))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme[.textPrimary])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("launcher.agent.\(kind.rawValue)")
                }
            }
            Button("launcher.openFolder", action: openFolder)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launcher.openFolder")
            Button("launcher.useForm") { environment.editorRequest = .newProject(.ungrouped) }
                .buttonStyle(.link)
                .accessibilityIdentifier("launcher.useForm")
        }
    }

    /// Opens a folder as a project (or the project already using it) and starts the chosen agent.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "sidebar.addProject.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.addProject")) { doc in
            let id = doc.projects.first { URL(filePath: $0.folder).standardizedFileURL.path == path }?.id
                ?? doc.addProject(name: url.lastPathComponent, folder: path, color: .next(after: doc.projects.count))
            doc.openInTab(id)
            doc.addPane(to: id, tab: PaneTab(agent: agent.rawValue, unrestricted: startsUnrestricted))
        }
        environment.preferences?.update { $0.lastAgent = agent.rawValue }
    }

    private var startsUnrestricted: Bool {
        AgentRegistry.builtin.descriptor(for: agent)?.unrestrictedFlag != nil
            && (environment.preferences?.document.alwaysStartUnrestricted ?? false)
    }
}

/// Launcher rows dim slightly while pressed.
private struct LauncherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
