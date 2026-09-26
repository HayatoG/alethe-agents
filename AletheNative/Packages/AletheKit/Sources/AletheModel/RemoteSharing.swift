import Foundation

/// A tab paired remote devices may see (upstream `remote/workspace.rs` `SharedTab`): every tab of a
/// pane the user shared (`Pane.remoteShared`). Everything else, including panes from before the
/// flag existed, stays private.
public struct RemoteSharedTerminal: Equatable, Sendable {
    public var tab: PaneTab
    public var paneID: PaneID
    public var projectID: ProjectID
    /// The tab's folder, else its project's.
    public var cwd: String

    public init(tab: PaneTab, paneID: PaneID, projectID: ProjectID, cwd: String) {
        self.tab = tab
        self.paneID = paneID
        self.projectID = projectID
        self.cwd = cwd
    }
}

extension WorkspaceDocument {
    /// Every tab of every shared terminal pane, in sidebar order of their projects.
    public var remoteSharedTerminals: [RemoteSharedTerminal] {
        projects.flatMap(remoteSharedTerminals(in:))
    }

    /// The shared tabs of one project (upstream `workspace_snapshot` chats).
    public func remoteSharedTerminals(in project: Project) -> [RemoteSharedTerminal] {
        project.panes.filter(\.isRemoteShared).flatMap { pane in
            pane.tabs.map { tab in
                let folder = tab.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemoteSharedTerminal(tab: tab, paneID: pane.id, projectID: project.id,
                                            cwd: folder.flatMap { $0.isEmpty ? nil : $0 } ?? project.folder)
            }
        }
    }

    /// The group directly holding a project; nil when it is ungrouped.
    public func groupID(holding project: ProjectID) -> GroupID? {
        if case .group(let id) = location(of: project) { return id }
        return nil
    }

    /// Shares or stops sharing a terminal pane with remote devices; nil when not shared keeps files
    /// written before the flag unchanged.
    public mutating func setRemoteShared(_ paneID: PaneID, _ shared: Bool) {
        updatePane(paneID) { pane in
            guard pane.content.isTerminal else { return }
            pane.remoteShared = shared ? true : nil
        }
    }
}
