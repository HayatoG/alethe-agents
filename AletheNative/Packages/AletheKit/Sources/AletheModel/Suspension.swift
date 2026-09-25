import Foundation

/// Disabling terminals and projects, suspending groups (upstream `setTerminalDisabled`,
/// `setProjectDisabled`, `suspendGroup` / `resumeGroup`). A disabled pane keeps its tabs and saved
/// output but runs nothing until enabled; a suspended group disables every project under it and
/// closes their containers, freeing their memory.
extension WorkspaceDocument {
    public func isProjectDisabled(_ id: ProjectID) -> Bool {
        guard let project = project(id), !project.panes.isEmpty else { return false }
        return project.panes.allSatisfy(\.isDisabled)
    }

    /// Projects in a group and every group below it.
    public func projectIDs(inGroupTree id: GroupID) -> [ProjectID] {
        groups.filter { isGroup($0.id, inside: id) }.flatMap(\.projectIDs)
    }

    /// The group itself or one above it is suspended.
    public func isSuspended(_ project: ProjectID) -> Bool {
        guard case .group(let group) = location(of: project) else { return false }
        return groups.contains { $0.suspended == true && isGroup(group, inside: $0.id) }
    }

    public mutating func setDisabled(_ paneID: PaneID, _ disabled: Bool) {
        updatePane(paneID) { $0.disabled = disabled ? true : nil }
    }

    /// Every pane of the project; disabling also closes its container.
    public mutating func setProjectDisabled(_ id: ProjectID, _ disabled: Bool) {
        updateProject(id) { project in
            for index in project.panes.indices { project.panes[index].disabled = disabled ? true : nil }
        }
        if disabled { close(id) }
    }

    public mutating func suspendGroup(_ id: GroupID) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].suspended != true else { return }
        for project in projectIDs(inGroupTree: id) { setProjectDisabled(project, true) }
        groups[index].suspended = true
    }

    public mutating func resumeGroup(_ id: GroupID) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].suspended == true else { return }
        for project in projectIDs(inGroupTree: id) { setProjectDisabled(project, false) }
        groups[index].suspended = nil
    }

    /// Tabs that must not run: those of disabled panes.
    public var disabledTabIDs: Set<TabID> {
        Set(projects.flatMap(\.panes).filter(\.isDisabled).flatMap { $0.tabs.map(\.id) })
    }
}

extension Pane {
    public var isDisabled: Bool { disabled == true }
}
