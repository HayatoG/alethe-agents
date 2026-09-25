import AletheAgents
import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// New Terminal sheet (⌘T): agent, project, folder, unrestricted mode and an optional first prompt.
/// Upstream: `NewTerminalModal` (basic form; grid picker, 9router and planner come later). With a
/// `targetPane` it is upstream's `NewSubTabModal`: the tab joins that pane, in the folder of the
/// pane's active tab.
struct NewTerminalSheet: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let initialProject: ProjectID?
    var targetPane: PaneID?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    @State private var agent: AgentKind = .claude
    @State private var projectID: ProjectID?
    @State private var folder = ""
    @State private var unrestricted = false
    @State private var prompt = ""
    /// Named grid the new terminal joins (P3-4); nil is the main grid.
    @State private var gridID: ProjectGridID?
    /// Model passed with the agent's model flag (P3-5); empty is the agent's default.
    @State private var model = ""
    @State private var models: [String] = []

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

            if targetPane == nil {
                Picker(selection: $projectID) {
                    ForEach(workspace.document.projects) { project in
                        Text(verbatim: project.name).tag(ProjectID?.some(project.id))
                    }
                } label: { Text("newTerminal.project") }
                    .onChange(of: projectID) { _, _ in
                        folder = project?.folder ?? ""
                        gridID = project?.shownGridID
                    }
                if let project, !project.namedGrids.isEmpty {
                    Picker(selection: $gridID) {
                        Text("projectGrid.main").tag(ProjectGridID?.none)
                        ForEach(project.namedGrids) { grid in
                            Text(verbatim: grid.name).tag(Optional(grid.id))
                        }
                    } label: { Text("newTerminal.grid") }
                        .accessibilityIdentifier("newTerminal.grid")
                }
            }

            LabeledContent("newTerminal.folder") {
                HStack {
                    TextField(text: $folder) { Text("newTerminal.folder") }
                        .labelsHidden()
                        .accessibilityIdentifier("newTerminal.folder")
                    Button("editor.project.chooseFolder") { chooseFolder() }
                }
            }

            if ModelDiscovery.modelFlag(for: agent) != nil {
                LabeledContent("newTerminal.model") {
                    HStack {
                        TextField(text: $model) { Text("newTerminal.model.default") }
                            .labelsHidden()
                            .accessibilityIdentifier("newTerminal.model")
                        if !models.isEmpty {
                            Menu {
                                Button("newTerminal.model.defaultItem") { model = "" }
                                Divider()
                                ForEach(models, id: \.self) { id in
                                    Button { model = id } label: { Text(verbatim: id) }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel(Text("newTerminal.model.choices"))
                            .accessibilityIdentifier("newTerminal.model.choices")
                        }
                    }
                }
                .task(id: agent) { await discoverModels() }
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
                Button(targetPane == nil ? LocalizedStringKey("newTerminal.create") : "newSubTab.add") { create() }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("editor.confirm")
            }
        }
        .navigationTitle(Text(targetPane == nil ? LocalizedStringKey("newTerminal.title") : "newSubTab.title"))
        .onAppear(perform: loadInitial)
        .onChange(of: agent) { _, _ in
            unrestricted = startsUnrestricted
            model = ""
        }
    }

    private var startsUnrestricted: Bool {
        descriptor?.unrestrictedFlag != nil && (environment.preferences?.document.alwaysStartUnrestricted ?? false)
    }

    private var problem: LocalizedStringKey? {
        guard project != nil else { return "newTerminal.problem.project" }
        if let targetPane, workspace.document.pane(targetPane) == nil { return "newSubTab.problem.pane" }
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
        gridID = project?.shownGridID
        if let targetPane, let found = workspace.document.pane(targetPane) {
            folder = found.pane.activeTab?.workingDirectory ?? found.project.folder
        }
        unrestricted = startsUnrestricted
    }

    /// The agent's models, looked up off the main thread; never blocks the sheet.
    private func discoverModels() async {
        models = []
        let executable = descriptor?.cliCommand.flatMap {
            environment.launchers.resolve($0, override: environment.preferences?.document.cliPaths?[agent.rawValue])
        }
        models = await ModelDiscovery.discover(agent, executable: executable)
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
            extraArguments: ModelDiscovery.arguments([], model: model, for: agent),
            initialPrompt: descriptor?.isShell == false && !text.isEmpty ? text : nil
        )
        if let targetPane {
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newSubTab")) {
                $0.addTab(tab, to: targetPane)
            }
        } else {
            let grid = gridID
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newTerminal")) {
                // New panes join the shown grid: show the chosen one first.
                if grid != $0.project(project.id)?.shownGridID { $0.activateGrid(grid, in: project.id) }
                $0.addPane(to: project.id, tab: tab)
            }
            environment.preferences?.update {
                $0.lastTerminalCreation = TerminalCreation(agent: tab.agent, folder: tab.workingDirectory,
                                                           unrestricted: tab.unrestricted, extraArguments: tab.extraArguments)
            }
        }
        environment.preferences?.update { $0.lastAgent = agent.rawValue }
        dismiss()
    }
}
