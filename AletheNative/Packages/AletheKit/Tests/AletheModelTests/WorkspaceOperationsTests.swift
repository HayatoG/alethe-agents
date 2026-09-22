import Foundation
import Testing
@testable import AletheModel

@Suite struct WorkspaceOperationsTests {
    private func sample() -> (WorkspaceDocument, GroupID, [ProjectID]) {
        var doc = WorkspaceDocument()
        let group = doc.addGroup(name: "Work")
        let a = doc.addProject(name: "A", folder: "/a", in: .group(group))
        let b = doc.addProject(name: "B", folder: "/b", in: .group(group))
        let c = doc.addProject(name: "C", folder: "/c")
        return (doc, group, [a, b, c])
    }

    private func everyProjectPlacedOnce(_ doc: WorkspaceDocument) -> Bool {
        let placed = doc.ungroupedProjectIDs + doc.groups.flatMap(\.projectIDs)
        return placed.count == doc.projects.count && Set(placed) == Set(doc.projects.map(\.id))
    }

    @Test func addingPlacesProjectsInOrder() {
        let (doc, group, ids) = sample()
        #expect(doc.group(group)?.projectIDs == [ids[0], ids[1]])
        #expect(doc.ungroupedProjectIDs == [ids[2]])
        #expect(everyProjectPlacedOnce(doc))
    }

    @Test func movingWithinTheSameListAccountsForRemoval() {
        var (doc, group, ids) = sample()
        doc.moveProject(ids[0], to: .group(group), at: 2)
        #expect(doc.group(group)?.projectIDs == [ids[1], ids[0]])
        doc.moveProject(ids[0], to: .group(group), at: 2)
        #expect(doc.group(group)?.projectIDs == [ids[1], ids[0]])
    }

    @Test func movingAcrossListsAndClamping() {
        var (doc, group, ids) = sample()
        doc.moveProject(ids[2], to: .group(group), at: 0)
        #expect(doc.group(group)?.projectIDs == [ids[2], ids[0], ids[1]])
        doc.moveProject(ids[0], to: .ungrouped, at: 99)
        #expect(doc.ungroupedProjectIDs == [ids[0]])
        #expect(everyProjectPlacedOnce(doc))
    }

    @Test func deletingAGroupKeepsItsProjectsAndChildren() {
        var (doc, group, ids) = sample()
        let child = doc.addGroup(name: "Child", parent: group)
        doc.moveProject(ids[2], to: .group(child), at: 0)
        doc.deleteGroup(group)
        #expect(doc.group(group) == nil)
        #expect(doc.group(child)?.parentID == nil)
        #expect(Set(doc.ungroupedProjectIDs) == [ids[0], ids[1]])
        #expect(doc.group(child)?.projectIDs == [ids[2]])
        #expect(everyProjectPlacedOnce(doc))
    }

    @Test func groupsCannotMoveIntoTheirOwnDescendants() {
        var (doc, group, _) = sample()
        let child = doc.addGroup(name: "Child", parent: group)
        let grandchild = doc.addGroup(name: "Grandchild", parent: child)
        doc.moveGroup(group, toParent: grandchild, at: 0)
        #expect(doc.group(group)?.parentID == nil)
        doc.moveGroup(grandchild, toParent: nil, at: 0)
        #expect(doc.group(grandchild)?.parentID == nil)
        #expect(doc.childGroups(of: nil).first?.id == grandchild)
    }

    @Test func removingAProjectCleansTheWorkspace() {
        var (doc, _, ids) = sample()
        doc.open(ids[0])
        doc.open(ids[1])
        doc.removeProject(ids[0])
        #expect(doc.workspace.openProjectIDs == [ids[1]])
        #expect(doc.project(ids[0]) == nil)
        #expect(everyProjectPlacedOnce(doc))
    }

    @Test func panesAddCloseAndSwap() throws {
        var (doc, _, ids) = sample()
        let firstID = doc.addPane(to: ids[0], tab: PaneTab(agent: "shell"))
        let secondID = doc.addPane(to: ids[0], tab: PaneTab(agent: "claude"))
        let first = try #require(firstID)
        let second = try #require(secondID)
        #expect(doc.workspace.openProjectIDs == [ids[0]])
        #expect(doc.workspace.focusedPaneID == second)
        doc.swapPanes(first, second)
        #expect(doc.project(ids[0])?.panes.map(\.id) == [second, first])
        doc.closePane(second)
        #expect(doc.project(ids[0])?.panes.map(\.id) == [first])
        #expect(doc.workspace.focusedPaneID == first)
    }

    @Test func tabUpdatesKeepTheirIdentity() throws {
        var (doc, _, ids) = sample()
        let tab = PaneTab(agent: "claude")
        doc.addPane(to: ids[0], tab: tab)
        doc.updateTab(tab.id) { $0.sessionID = "abc"; $0.id = .make() }
        #expect(doc.project(ids[0])?.panes.first?.tabs.first?.id == tab.id)
        #expect(doc.project(ids[0])?.panes.first?.tabs.first?.sessionID == "abc")
    }

    @Test func repairDropsDanglingReferencesAndPlacesOrphans() {
        var doc = WorkspaceDocument()
        let orphan = Project(name: "Orphan", folder: "/o")
        doc.projects = [orphan]
        doc.ungroupedProjectIDs = [ProjectID(rawValue: "ghost")]
        doc.groups = [ProjectGroup(name: "G", parentID: GroupID(rawValue: "missing"), projectIDs: [orphan.id, orphan.id])]
        doc.workspace.openProjectIDs = [ProjectID(rawValue: "ghost")]
        doc.repair()
        #expect(doc.groups[0].projectIDs == [orphan.id])
        #expect(doc.ungroupedProjectIDs.isEmpty)
        #expect(doc.groups[0].parentID == nil)
        #expect(doc.workspace.openProjectIDs.isEmpty)
    }

    @Test func documentRoundTripsThroughJSON() throws {
        var (doc, _, ids) = sample()
        doc.addPane(to: ids[1], tab: PaneTab(agent: "codex", sessionID: "s1", unrestricted: true, extraArguments: ["--x"]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceDocument.self, from: encoder.encode(doc))
        #expect(decoded.projects.map(\.id) == doc.projects.map(\.id))
        #expect(decoded.project(ids[1])?.panes.first?.tabs.first?.sessionID == "s1")
        #expect(decoded.groups == doc.groups)
    }
}

@Suite struct PreferencesTests {
    @Test func zoomStepsAndClamps() {
        var prefs = PreferencesDocument()
        prefs.zoom(by: 1)
        #expect(prefs.uiScale == 1.1)
        prefs.zoom(by: 20)
        #expect(prefs.uiScale == 1.5)
        prefs.zoom(by: -20)
        #expect(prefs.uiScale == 0.8)
    }
}

@Suite struct DocumentModelTests {
    @MainActor @Test func updatesPersistAndReload() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "alethe-\(UUID().uuidString)/workspace.json")
        let model = await WorkspaceModel.load(from: url)
        #expect(model.loadOutcome == .fresh)
        model.update { _ = $0.addProject(name: "Persisted", folder: "/p") }
        await model.flush()
        let reloaded = await WorkspaceModel.load(from: url)
        #expect(reloaded.document.projects.map(\.name) == ["Persisted"])
    }
}
