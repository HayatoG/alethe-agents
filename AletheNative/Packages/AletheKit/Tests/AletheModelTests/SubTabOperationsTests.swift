import Foundation
import Testing
@testable import AletheModel

/// Sub-tabs of a pane (upstream `createSubTab` / `closeSubTab` / `setActiveTab` / `setLaneVisible`).
@Suite struct SubTabOperationsTests {
    private func sample(tabs count: Int) -> (WorkspaceDocument, ProjectID, PaneID, [TabID]) {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "a", folder: "/a")
        let tabs = (0..<count).map { PaneTab(agent: $0 == 0 ? "shell" : "claude", title: "t\($0)") }
        let pane = doc.addPane(to: project, tab: tabs[0])!
        for tab in tabs.dropFirst() { doc.addTab(tab, to: pane) }
        return (doc, project, pane, tabs.map(\.id))
    }

    @Test func addingATabShowsAndFocusesIt() {
        var (doc, project, pane, tabs) = sample(tabs: 1)
        doc.workspace.focusedPaneID = nil
        doc.close(project)
        let added = PaneTab(agent: "codex")
        let wasAdded = doc.addTab(added, to: pane)
        #expect(wasAdded)
        #expect(doc.pane(pane)?.pane.tabs.map(\.id) == tabs + [added.id])
        #expect(doc.pane(pane)?.pane.activeTabID == added.id)
        #expect(doc.workspace.focusedPaneID == pane)
        #expect(doc.workspace.openProjectIDs == [project])
    }

    @Test func addingToAMissingPaneDoesNothing() {
        var (doc, _, _, _) = sample(tabs: 1)
        let before = doc
        let wasAdded = doc.addTab(PaneTab(agent: "shell"), to: .make())
        #expect(!wasAdded)
        #expect(doc == before)
    }

    @Test func closingTheActiveTabShowsTheNextThenThePrevious() {
        var (doc, _, pane, tabs) = sample(tabs: 3)
        doc.activateTab(tabs[1])
        doc.closeTab(tabs[1])
        #expect(doc.pane(pane)?.pane.activeTabID == tabs[2])
        doc.closeTab(tabs[2])
        #expect(doc.pane(pane)?.pane.activeTabID == tabs[0])
    }

    @Test func closingAnInactiveTabKeepsTheActiveOne() {
        var (doc, _, pane, tabs) = sample(tabs: 3)
        doc.closeTab(tabs[0])
        #expect(doc.pane(pane)?.pane.activeTabID == tabs[2])
        #expect(doc.pane(pane)?.pane.tabs.map(\.id) == [tabs[1], tabs[2]])
    }

    @Test func activatingSelectsTheProjectAndFocusesThePane() {
        var (doc, project, pane, tabs) = sample(tabs: 2)
        doc.workspace.focusedPaneID = nil
        doc.workspace.selectedProjectID = nil
        doc.activateTab(tabs[0])
        #expect(doc.pane(pane)?.pane.activeTabID == tabs[0])
        #expect(doc.workspace.focusedPaneID == pane)
        #expect(doc.workspace.selectedProjectID == project)
    }

    @Test func cyclingWrapsAround() {
        var (doc, _, pane, tabs) = sample(tabs: 3)
        doc.activateTab(tabs[2])
        #expect(doc.tab(1, from: pane) == tabs[0])
        #expect(doc.tab(-1, from: pane) == tabs[1])
        doc.activateTab(tabs[0])
        #expect(doc.tab(-1, from: pane) == tabs[2])
    }

    @Test func laneIsShownWithSeveralTabsOrWhenAskedFor() {
        var (doc, _, pane, _) = sample(tabs: 1)
        #expect(doc.pane(pane)?.pane.isLaneVisible == false)
        doc.setLaneVisible(true, for: pane)
        #expect(doc.pane(pane)?.pane.isLaneVisible == true)
        doc.setLaneVisible(false, for: pane)
        #expect(doc.pane(pane)?.pane.laneVisible == nil)
        doc.addTab(PaneTab(agent: "claude"), to: pane)
        #expect(doc.pane(pane)?.pane.isLaneVisible == true)
    }

    @Test func laneVisibilityIsOptionalInTheFile() throws {
        let (doc, _, pane, _) = sample(tabs: 1)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        var projects = try #require(json["projects"] as? [[String: Any]])
        var panes = try #require(projects[0]["panes"] as? [[String: Any]])
        panes[0].removeValue(forKey: "laneVisible")
        projects[0]["panes"] = panes
        json["projects"] = projects
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.pane(pane)?.pane.laneVisible == nil)
    }
}

@Suite struct PromptHistoryDocumentTests {
    @Test func pruneKeepsOnlyExistingTabs() {
        let kept = TabID.make(), gone = TabID.make()
        var doc = PromptHistoryDocument(histories: [kept.rawValue: ["a"], gone.rawValue: ["b"]])
        doc.prune(keeping: [kept])
        #expect(doc.histories == [kept.rawValue: ["a"]])
    }
}
