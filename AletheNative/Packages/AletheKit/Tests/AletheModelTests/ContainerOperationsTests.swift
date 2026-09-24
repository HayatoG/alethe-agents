import Foundation
import Testing
@testable import AletheModel

@Suite struct ContainerOperationsTests {
    private func sample() -> (WorkspaceDocument, [ProjectID], PaneID) {
        var doc = WorkspaceDocument()
        let ids = ["a", "b", "c"].map { doc.addProject(name: $0, folder: "/\($0)") }
        var pane: PaneID!
        for id in ids { pane = doc.addPane(to: id, tab: PaneTab(agent: "shell")) }
        doc.workspace.containerWeights = [0.5, 0.3, 0.2]
        return (doc, ids, pane)
    }

    @Test func movingAContainerCarriesItsWidth() {
        var (doc, ids, _) = sample()
        doc.moveContainer(ids[0], to: 2)
        #expect(doc.workspace.openProjectIDs == [ids[1], ids[2], ids[0]])
        #expect(doc.workspace.containerWeights == [0.3, 0.2, 0.5])
        doc.moveContainer(ids[0], to: 99)
        #expect(doc.workspace.openProjectIDs.last == ids[0], "clamped")
    }

    @Test func collapseFullscreenAndIsolation() {
        var (doc, ids, pane) = sample()
        doc.setCollapsed(ids[0], true)
        #expect(doc.workspace.collapsedProjectIDs == [ids[0]])
        doc.setFullscreen(ids[0])
        #expect(doc.workspace.fullscreenProjectID == ids[0])
        #expect(doc.workspace.collapsedProjectIDs.isEmpty, "a project shown alone is expanded")
        doc.isolate(pane)
        #expect(doc.workspace.isolatedPaneID == pane)
        #expect(doc.workspace.fullscreenProjectID == ids[2], "isolating shows the pane's project alone")
        #expect(doc.workspace.focusedPaneID == pane)
        doc.isolate(nil)
        #expect(doc.workspace.isolatedPaneID == nil && doc.workspace.fullscreenProjectID == nil)
        doc.setFullscreen(ids[1])
        doc.setCollapsed(ids[1], true)
        #expect(doc.workspace.fullscreenProjectID == nil, "collapsing leaves fullscreen")
    }

    @Test func closingForgetsContainerState() {
        var (doc, ids, pane) = sample()
        doc.isolate(pane)
        doc.closePane(pane)
        #expect(doc.workspace.isolatedPaneID == nil)
        doc.setFullscreen(ids[0])
        doc.setCollapsed(ids[1], true)
        doc.close(ids[0])
        #expect(doc.workspace.fullscreenProjectID == nil)
        doc.removeProject(ids[1])
        #expect(doc.workspace.collapsedProjectIDs.isEmpty)
    }

    @Test func repairDropsStaleState() {
        var (doc, ids, _) = sample()
        doc.workspace.collapsedProjectIDs = [ids[0], .make()]
        doc.workspace.fullscreenProjectID = .make()
        doc.workspace.isolatedPaneID = .make()
        doc.repair()
        #expect(doc.workspace.collapsedProjectIDs == [ids[0]])
        #expect(doc.workspace.fullscreenProjectID == nil)
        #expect(doc.workspace.isolatedPaneID == nil)
    }

    @Test func olderWorkspaceStateDecodes() throws {
        let json = #"{"openProjectIDs":[],"containerWeights":[],"gridWeights":{}}"#
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.collapsedProjectIDs.isEmpty && state.fullscreenProjectID == nil && state.isolatedPaneID == nil)
    }
}
