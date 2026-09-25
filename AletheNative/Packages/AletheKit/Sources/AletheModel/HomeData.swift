import Foundation

public enum Greeting: String, Sendable {
    case morning, afternoon, evening

    /// Upstream `getGreeting`: 5–12 morning, 12–18 afternoon, evening otherwise.
    public init(hour: Int) {
        self = (5..<12).contains(hour) ? .morning : (12..<18).contains(hour) ? .afternoon : .evening
    }
}

extension WorkspaceDocument {
    /// Home's recent projects (upstream `recentProjects`): the projects of the navigation history, newest
    /// visit first, then the open ones and those of the tab bar, then the rest in sidebar order.
    public func recentProjectIDs(limit: Int = 6) -> [ProjectID] {
        var ordered: [ProjectID] = []
        func add(_ id: ProjectID?) {
            guard let id, !ordered.contains(id), project(id) != nil else { return }
            ordered.append(id)
        }
        for entry in workspace.history.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            entry.snapshot.selectedProjectID.map { add($0) }
            entry.snapshot.openProjectIDs.forEach(add)
        }
        workspace.openProjectIDs.forEach(add)
        for tab in workspace.tabs.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            add(tab.projectID)
            tab.snapshot.openProjectIDs.forEach(add)
        }
        projects.map(\.id).forEach(add)
        return Array(ordered.prefix(max(limit, 0)))
    }
}
