import Foundation
import Testing
@testable import AletheModel

/// Disable terminals and projects, suspend groups (P2-23).
@Suite struct SuspensionTests {
    @Test func disablingATerminal() {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "p", folder: "/p")
        let paneID = doc.addPane(to: project, tab: PaneTab(agent: "shell"))
        let pane = try! #require(paneID)
        doc.setDisabled(pane, true)
        #expect(doc.pane(pane)?.pane.isDisabled == true)
        #expect(doc.disabledTabIDs == Set(doc.pane(pane)?.pane.tabs.map(\.id) ?? []))
        #expect(doc.isProjectDisabled(project), "its only pane is disabled")
        doc.setDisabled(pane, false)
        #expect(doc.pane(pane)?.pane.disabled == nil && doc.disabledTabIDs.isEmpty)
    }

    @Test func disablingAProjectClosesItsContainer() {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "p", folder: "/p")
        for _ in 0..<2 { doc.addPane(to: project, tab: PaneTab(agent: "shell")) }
        doc.setProjectDisabled(project, true)
        #expect(doc.isProjectDisabled(project))
        #expect(!doc.workspace.openProjectIDs.contains(project))
        doc.setProjectDisabled(project, false)
        #expect(!doc.isProjectDisabled(project))
        #expect(!doc.isProjectDisabled(doc.addProject(name: "empty", folder: "/e")), "a project without panes is never disabled")
    }

    @Test func suspendingAGroupReachesNestedProjects() {
        var doc = WorkspaceDocument()
        let work = doc.addGroup(name: "Work")
        let clients = doc.addGroup(name: "Clients", parent: work)
        let a = doc.addProject(name: "a", folder: "/a", in: .group(work))
        let b = doc.addProject(name: "b", folder: "/b", in: .group(clients))
        let outside = doc.addProject(name: "c", folder: "/c")
        for id in [a, b, outside] { doc.addPane(to: id, tab: PaneTab(agent: "shell")) }
        doc.suspendGroup(work)
        #expect(doc.group(work)?.suspended == true)
        #expect(doc.isProjectDisabled(a) && doc.isProjectDisabled(b) && !doc.isProjectDisabled(outside))
        #expect(doc.isSuspended(b), "a subgroup's project is under the suspended group")
        #expect(doc.workspace.openProjectIDs == [outside])
        doc.resumeGroup(work)
        #expect(doc.group(work)?.suspended == nil && !doc.isProjectDisabled(b))
    }

    @Test func olderGroupsAndPanesDecode() throws {
        let group = try JSONDecoder().decode(ProjectGroup.self, from: Data(#"{"id":"g","name":"G","projectIDs":[],"isCollapsed":false}"#.utf8))
        #expect(group.suspended == nil)
    }
}
