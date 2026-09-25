import AletheDesign
import AletheModel
import SwiftUI

/// Projects organized in nested groups, with each project's terminals underneath.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.undoManager) private var undoManager
    @Environment(\.metrics) private var metrics

    var body: some View {
        if let workspace = environment.workspace {
            content(workspace)
        } else {
            List {}.listStyle(.sidebar)
        }
    }

    private func content(_ workspace: WorkspaceModel) -> some View {
        let actions = SidebarActions(workspace: workspace, undoManager: undoManager)
        let doc = workspace.document
        return List(selection: selection(workspace, actions)) {
            Section("sidebar.projects.header") {
                ForEach(doc.childGroups(of: nil)) { group in
                    GroupRow(group: group, actions: actions)
                }
                .onInsert(of: [.plainText]) { index, providers in
                    SidebarDrag.load(providers) { actions.insertGroup($0, under: nil, at: index) }
                }
                ForEach(doc.ungroupedProjectIDs, id: \.self) { id in
                    if let project = doc.project(id) {
                        ProjectRow(project: project, actions: actions)
                    }
                }
                .onMove { source, destination in actions.reorder(in: .ungrouped, from: source, to: destination) }
                .onInsert(of: [.plainText]) { index, providers in
                    SidebarDrag.load(providers) { actions.insert($0, into: .ungrouped, at: index) }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
        .dropDestination(for: URL.self) { urls, _ in
            let added = actions.addProjects(folders: urls)
            return !added.isEmpty
        }
        .contextMenu {
            Button("menu.file.newProject") { environment.editorRequest = .newProject(.ungrouped) }
            Button("sidebar.addProject") { actions.chooseFolders() }
            Button("menu.file.newGroup") { environment.editorRequest = .newGroup(parent: nil) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { actions.chooseFolders() } label: {
                    Label("sidebar.addProject", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sidebar.addProject")
                Spacer()
            }
            .padding(.horizontal, metrics.space(.l))
            .padding(.vertical, metrics.space(.m))
        }
    }

    private func selection(_ workspace: WorkspaceModel, _ actions: SidebarActions) -> Binding<SidebarItem?> {
        Binding {
            let state = workspace.document.workspace
            if let focused = state.focusedPaneID, let (project, pane) = workspace.document.pane(focused),
               project.id == state.selectedProjectID, let tab = pane.activeTab {
                return .tab(tab.id)
            }
            return state.selectedProjectID.map(SidebarItem.project)
        } set: { item in
            actions.select(item)
        }
    }
}

private struct GroupRow: View {
    let group: ProjectGroup
    let actions: SidebarActions
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        let doc = actions.workspace.document
        DisclosureGroup(isExpanded: Binding {
            !group.isCollapsed
        } set: { expanded in
            actions.setCollapsed(group.id, !expanded)
        }) {
            ForEach(doc.childGroups(of: group.id)) { child in
                GroupRow(group: child, actions: actions)
            }
            .onInsert(of: [.plainText]) { index, providers in
                SidebarDrag.load(providers) { actions.insertGroup($0, under: group.id, at: index) }
            }
            ForEach(group.projectIDs, id: \.self) { id in
                if let project = doc.project(id) {
                    ProjectRow(project: project, actions: actions)
                }
            }
            .onMove { source, destination in actions.reorder(in: .group(group.id), from: source, to: destination) }
            .onInsert(of: [.plainText]) { index, providers in
                SidebarDrag.load(providers) { actions.insert($0, into: .group(group.id), at: index) }
            }
        } label: {
            Label {
                Text(verbatim: group.name)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(group.color.map { theme[$0.token] } ?? theme[.textSecondary])
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                SidebarDrag.load(providers) { actions.drop($0, onGroup: group.id) }
                return true
            }
            .contextMenu {
                Button("sidebar.editGroup") { environment.editorRequest = .editGroup(group.id) }
                Button("sidebar.newProjectHere") { environment.editorRequest = .newProject(.group(group.id)) }
                Button("sidebar.newSubgroup") { environment.editorRequest = .newGroup(parent: group.id) }
                Divider()
                Button("sidebar.deleteGroup") { actions.deleteGroup(group.id) }
            }
            .accessibilityIdentifier("sidebar.group.\(group.name)")
        }
        .tag(SidebarItem.group(group.id))
        .itemProvider { NSItemProvider(object: SidebarDrag.payload(group.id) as NSString) }
    }
}

private struct ProjectRow: View {
    let project: Project
    let actions: SidebarActions
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        let tabs = project.panes.flatMap(\.tabs)
        Group {
            if tabs.isEmpty {
                label
            } else {
                DisclosureGroup {
                    ForEach(tabs) { tab in
                        Label {
                            Text(verbatim: tab.title ?? AgentLabels.name(for: tab.agent))
                        } icon: {
                            Image(systemName: tab.agent == "shell" ? "terminal" : "sparkles")
                                .foregroundStyle(theme[.textSecondary])
                        }
                        .tag(SidebarItem.tab(tab.id))
                        .contextMenu { TabContextMenu(tab: tab, project: project, actions: actions) }
                        .accessibilityIdentifier("sidebar.tab.\(tab.agent)")
                    }
                } label: {
                    label
                }
            }
        }
        .tag(SidebarItem.project(project.id))
        .itemProvider { NSItemProvider(object: SidebarDrag.payload(project.id) as NSString) }
    }

    private var label: some View {
        Label {
            Text(verbatim: project.name)
        } icon: {
            Circle()
                .fill(theme[project.color.token])
                .frame(width: metrics.size(8), height: metrics.size(8))
        }
        .help(Text(verbatim: project.folder))
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            SidebarDrag.load(providers) { actions.drop($0, onProject: project.id) }
            return true
        }
        .contextMenu { ProjectContextMenu(project: project, actions: actions) }
        .accessibilityIdentifier("sidebar.project.\(project.name)")
    }
}

private struct ProjectContextMenu: View {
    let project: Project
    let actions: SidebarActions
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let doc = actions.workspace.document
        NewTerminalButton(project: project)
        Divider()
        Button("sidebar.editProject") { environment.editorRequest = .editProject(project.id) }
        Button("sidebar.revealInFinder") { actions.revealInFinder(project) }
        Menu("sidebar.moveToGroup") {
            Button("sidebar.ungrouped") { actions.move(project.id, to: .ungrouped) }
                .disabled(doc.location(of: project.id) == .ungrouped)
            if !doc.groups.isEmpty { Divider() }
            ForEach(doc.groups) { group in
                Button { actions.move(project.id, to: .group(group.id)) } label: { Text(verbatim: group.name) }
                    .disabled(doc.location(of: project.id) == .group(group.id))
            }
        }
        Menu("sidebar.grids") {
            Button("projectGrid.main") { actions.workspace.update { $0.activateGrid(nil, in: project.id) } }
            ForEach(project.namedGrids) { grid in
                Button { actions.workspace.update { $0.activateGrid(grid.id, in: project.id) } } label: { Text(verbatim: grid.name) }
            }
            Divider()
            Button("projectGrid.newEllipsis") {
                ProjectGridPrompts.createGrid(in: project.id, workspace: actions.workspace, undoManager: actions.undoManager)
            }
        }
        Divider()
        Button("sidebar.removeProject") { actions.remove(project.id) }
    }
}

private struct TabContextMenu: View {
    let tab: PaneTab
    let project: Project
    let actions: SidebarActions
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button("terminal.restart") { environment.terminals.restart(tab, in: project, environment: environment) }
        if let pane = actions.workspace.document.paneHolding(tab.id)?.pane {
            Divider()
            Button("subtabs.newEllipsis") { environment.editorRequest = .newSubTab(pane.id) }
            Button(pane.isLaneVisible ? LocalizedStringKey("subtabs.hideLane") : "subtabs.showLane") {
                actions.setLaneVisible(!pane.isLaneVisible, for: pane.id)
            }
            .disabled(pane.tabs.count > 1)
        }
        Divider()
        Button("terminal.close") { actions.closeTab(tab.id) }
    }
}

/// Display names of agents (product names, not translated).
enum AgentLabels {
    static func name(for agent: String) -> String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "cursor": "Cursor"
        case "shell": "Shell"
        default: agent
        }
    }
}
