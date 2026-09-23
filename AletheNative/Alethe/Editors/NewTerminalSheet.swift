import AletheAgents
import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// New Terminal sheet (⌘T): agent, project, folder, unrestricted mode and an optional first prompt.
/// Upstream: `NewTerminalModal` (basic form; grid picker, 9router and planner come later).
struct NewTerminalSheet: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let initialProject: ProjectID?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    @State private var agent: AgentKind = .claude
    @State private var projectID: ProjectID?
    @State private var folder = ""
    @State private var unrestricted = false
    @State private var prompt = ""

    private var registry: AgentRegistry { .builtin }
    private var agents: [AgentKind] { registry.enabledKinds(environment.preferences?.document.enabledAgents) }
    private var project: Project? { projectID.flatMap { workspace.document.project($0) } }
    private var descriptor: AgentDescriptor? { registry.descriptor(for: agent) }

    var body: some View {
        Form {
            Picker(selection: $agent) {
                ForEach(agents, id: \.self) { kind in
                    Label {
                        Text(verbatim: AgentLabels.name(for: kind.rawValue))
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(theme[AgentTokens.accent(for: kind.rawValue)])
                    }
                    .tag(kind)
                }
            } label: { Text("newTerminal.agent") }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("newTerminal.agent")

            Picker(selection: $projectID) {
                ForEach(workspace.document.projects) { project in
                    Text(verbatim: project.name).tag(ProjectID?.some(project.id))
                }
            } label: { Text("newTerminal.project") }
                .onChange(of: projectID) { _, _ in folder = project?.folder ?? "" }

            LabeledContent("newTerminal.folder") {
                HStack {
                    TextField(text: $folder) { Text("newTerminal.folder") }
                        .labelsHidden()
                        .accessibilityIdentifier("newTerminal.folder")
                    Button("editor.project.chooseFolder") { chooseFolder() }
                }
            }

            if let flag = descriptor?.unrestrictedFlag {
                Toggle(isOn: $unrestricted) {
                    Text("newTerminal.unrestricted")
                    Text(verbatim: flag).font(metrics.font(.footnote).monospaced())
                }
                .accessibilityIdentifier("newTerminal.unrestricted")
            }

            if descriptor?.isShell == false {
                LabeledContent("newTerminal.prompt") {
                    TextEditor(text: $prompt)
                        .font(metrics.font(.body))
                        .frame(minHeight: metrics.size(70))
                        .scrollContentBackground(.hidden)
                        .padding(metrics.space(.xs))
                        .background(theme[.bgSunken], in: RoundedRectangle(cornerRadius: metrics.radius(.sm)))
                        .overlay(RoundedRectangle(cornerRadius: metrics.radius(.sm)).strokeBorder(theme[.border]))
                        .accessibilityIdentifier("newTerminal.prompt")
                }
            }

            if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .font(metrics.font(.footnote))
                    .accessibilityIdentifier("editor.problem")
            }
        }
        .formStyle(.grouped)
        .frame(width: metrics.size(480))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("editor.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("newTerminal.create") { create() }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("editor.confirm")
            }
        }
        .navigationTitle(Text("newTerminal.title"))
        .onAppear(perform: loadInitial)
        .onChange(of: agent) { _, _ in unrestricted = startsUnrestricted }
    }

    private var startsUnrestricted: Bool {
        descriptor?.unrestrictedFlag != nil && (environment.preferences?.document.alwaysStartUnrestricted ?? false)
    }

    private var problem: LocalizedStringKey? {
        guard project != nil else { return "newTerminal.problem.project" }
        var isDirectory: ObjCBool = false
        let path = expanded(folder)
        if path.isEmpty || !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return "editor.problem.folder"
        }
        return nil
    }

    private func loadInitial() {
        let last = registry.parse(environment.preferences?.document.lastAgent)
        agent = last.flatMap { agents.contains($0) ? $0 : nil } ?? (agents.contains(.claude) ? .claude : agents.first ?? .shell)
        projectID = initialProject.flatMap { workspace.document.project($0)?.id } ?? workspace.document.projects.first?.id
        folder = project?.folder ?? ""
        unrestricted = startsUnrestricted
    }

    private func expanded(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(filePath: expanded(folder), directoryHint: .isDirectory)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        guard let project else { return }
        let path = URL(filePath: expanded(folder)).standardizedFileURL.path
        let projectFolder = URL(filePath: project.folder).standardizedFileURL.path
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = PaneTab(
            agent: agent.rawValue,
            workingDirectory: path == projectFolder ? nil : path,
            unrestricted: descriptor?.unrestrictedFlag != nil && unrestricted,
            initialPrompt: descriptor?.isShell == false && !text.isEmpty ? text : nil
        )
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newTerminal")) {
            $0.addPane(to: project.id, tab: tab)
        }
        environment.preferences?.update { $0.lastAgent = agent.rawValue }
        dismiss()
    }
}
