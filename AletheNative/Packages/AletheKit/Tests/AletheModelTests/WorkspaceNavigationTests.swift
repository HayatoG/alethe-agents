import Foundation
import Testing
@testable import AletheModel

/// Port of upstream `workspaceNavigation.test.ts`, plus the tab operations of the store.
@Suite struct WorkspaceNavigationTests {
    private func sample() -> (WorkspaceDocument, [ProjectID]) {
        var doc = WorkspaceDocument()
        let ids = ["a", "b", "c"].map { doc.addProject(name: $0, folder: "/\($0)") }
        return (doc, ids)
    }

    private func entry(_ tab: WorkspaceTabID) -> WorkspaceHistoryEntry {
        WorkspaceHistoryEntry(tabID: tab, snapshot: WorkspaceSnapshot())
    }

    @Test func pushingHistoryTruncatesTheForwardBranch() {
        var doc = WorkspaceDocument()
        let first = entry(.make()), second = entry(.make()), third = entry(.make())
        doc.pushHistory(first)
        doc.pushHistory(second)
        doc.workspace.historyIndex = 0
        doc.pushHistory(third)
        #expect(doc.workspace.history.map(\.id) == [first.id, third.id])
        #expect(doc.workspace.historyIndex == 1)
    }

    @Test func historyKeepsOnlyTheLatestEntries() {
        var doc = WorkspaceDocument()
        let entries = (0..<(WorkspaceDocument.maxWorkspaceHistory + 5)).map { _ in entry(.make()) }
        for item in entries { doc.pushHistory(item) }
        #expect(doc.workspace.history.count == WorkspaceDocument.maxWorkspaceHistory)
        #expect(doc.workspace.history.first?.id == entries[5].id)
    }

    @Test func sanitizingRemovesMissingProjectsAndPanes() {
        let (doc, ids) = sample()
        let dirty = WorkspaceSnapshot(openProjectIDs: [.make()], containerWeights: [1], focusedPaneID: .make(),
                                      selectedProjectID: .make(), fullscreenProjectID: .make())
        let clean = doc.sanitized(dirty)
        #expect(clean.openProjectIDs.isEmpty && clean.containerWeights.isEmpty)
        #expect(clean.selectedProjectID == nil && clean.focusedPaneID == nil && clean.fullscreenProjectID == nil)
        let kept = doc.sanitized(WorkspaceSnapshot(openProjectIDs: [ids[0], .make()], selectedProjectID: ids[0]))
        #expect(kept.openProjectIDs == [ids[0]] && kept.selectedProjectID == ids[0])
    }

    @Test func compositionLabelsCountTheOtherProjects() {
        let (doc, ids) = sample()
        let tab = WorkspaceTab(kind: .composition, snapshot: WorkspaceSnapshot(openProjectIDs: [ids[1], ids[2]]))
        #expect(doc.label(of: tab)?.name == "b" && doc.label(of: tab)?.more == 1)
        #expect(doc.label(of: WorkspaceTab(kind: .composition, snapshot: WorkspaceSnapshot())) == nil)
    }

    @Test func openingProjectsMakesOneTabEach() {
        var (doc, ids) = sample()
        doc.openInTab(ids[0])
        doc.openInTab(ids[1])
        #expect(doc.workspace.tabs.count == 2)
        #expect(doc.workspace.openProjectIDs == [ids[1]])
        doc.openInTab(ids[0])
        #expect(doc.workspace.tabs.count == 2, "a project tab is reused")
        #expect(doc.activeWorkspaceTab?.projectID == ids[0])
        #expect(doc.workspace.history.count == 3)
    }

    @Test func backAndForwardRestoreVisitedViews() {
        var (doc, ids) = sample()
        doc.openInTab(ids[0])
        doc.openInTab(ids[1])
        #expect(doc.canGoBack && !doc.canGoForward)
        doc.navigateHistory(-1)
        #expect(doc.workspace.openProjectIDs == [ids[0]])
        #expect(doc.canGoForward)
        doc.navigateHistory(1)
        #expect(doc.workspace.openProjectIDs == [ids[1]])
        doc.navigateHistory(1)
        #expect(doc.workspace.historyIndex == 1, "past the end is ignored")
    }

    @Test func theActiveTabFollowsTheLiveView() {
        var (doc, ids) = sample()
        doc.openInTab(ids[0])
        doc.open(ids[1])
        doc.syncActiveTab()
        let tab = doc.activeWorkspaceTab
        #expect(tab?.snapshot.openProjectIDs == [ids[0], ids[1]])
        #expect(tab?.kind == .composition, "a project tab showing more becomes a composition")
        #expect(doc.workspace.history.last?.snapshot.openProjectIDs == [ids[0], ids[1]])
    }

    @Test func closingAndReopeningTabs() {
        var (doc, ids) = sample()
        doc.openInTab(ids[0])
        doc.openInTab(ids[1])
        doc.openInTab(ids[2])
        let middle = doc.workspace.tabs[1].id
        doc.activateWorkspaceTab(middle)
        doc.closeWorkspaceTab(middle)
        #expect(doc.workspace.tabs.count == 2)
        #expect(doc.workspace.openProjectIDs == [ids[2]], "the next tab is shown")
        #expect(doc.workspace.history.allSatisfy { $0.tabID != middle })
        doc.reopenClosedWorkspaceTab()
        #expect(doc.workspace.activeTabID == middle)
        #expect(doc.workspace.openProjectIDs == [ids[1]])
        #expect(doc.workspace.closedTabs.isEmpty)
        for tab in doc.workspace.tabs { doc.closeWorkspaceTab(tab.id) }
        #expect(doc.workspace.openProjectIDs.isEmpty && doc.workspace.activeTabID == nil)
        #expect(doc.workspace.historyIndex == -1)
    }

    @Test func theBarDropsTheOldestUnpinnedTabPastTheLimit() {
        var doc = WorkspaceDocument()
        let ids = (0...WorkspaceDocument.maxWorkspaceTabs).map { doc.addProject(name: "p\($0)", folder: "/p\($0)") }
        doc.openInTab(ids[0])
        doc.togglePinned(doc.workspace.tabs[0].id)
        for id in ids.dropFirst() { doc.openInTab(id) }
        #expect(doc.workspace.tabs.count == WorkspaceDocument.maxWorkspaceTabs)
        #expect(doc.workspace.tabs.first?.projectID == ids[0], "the pinned tab stays")
        #expect(!doc.workspace.tabs.contains { $0.projectID == ids[1] })
    }

    @Test func cyclingTabsWraps() {
        var (doc, ids) = sample()
        for id in ids { doc.openInTab(id) }
        #expect(doc.workspaceTab(1) == doc.workspace.tabs[0].id)
        #expect(doc.workspaceTab(-1) == doc.workspace.tabs[1].id)
    }

    @Test func repairMakesAFirstTabAndDropsDeletedProjects() {
        var (doc, ids) = sample()
        doc.open(ids[0])
        doc.open(ids[1])
        doc.repair()
        #expect(doc.workspace.tabs.count == 1 && doc.activeWorkspaceTab?.kind == .composition)
        doc.openInTab(ids[2])
        doc.removeProject(ids[2])
        #expect(doc.workspace.tabs.count == 1, "a project tab goes with its project")
    }

    @Test func olderWorkspaceStateDecodesWithoutTabs() throws {
        let json = #"{"openProjectIDs":[],"containerWeights":[],"gridWeights":{}}"#
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.tabs.isEmpty && state.history.isEmpty && state.historyIndex == -1)
    }
}
