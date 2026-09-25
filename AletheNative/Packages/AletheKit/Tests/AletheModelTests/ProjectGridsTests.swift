import Foundation
import Testing
@testable import AletheModel

/// Named project grids (P2-20, upstream `projectGrids.ts` and the grid slices).
@Suite struct ProjectGridsTests {
    private func sample() -> (WorkspaceDocument, ProjectID, [PaneID]) {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "p", folder: "/p")
        let panes = ["one", "two"].compactMap { doc.addPane(to: project, tab: PaneTab(agent: "shell", title: $0)) }
        return (doc, project, panes)
    }

    @Test func namesAreValidated() {
        var (doc, project, _) = sample()
        #expect(doc.gridNameProblem("  ", in: project) == .empty)
        #expect(doc.gridNameProblem("Main", in: project) == .reserved)
        #expect(doc.gridNameProblem("Principal", in: project) == .reserved)
        doc.createGrid(named: "Review", in: project)
        #expect(doc.gridNameProblem("review", in: project) == .taken)
        let review = try! #require(doc.project(project)?.namedGrids.first?.id)
        #expect(doc.gridNameProblem("Review", in: project, except: review) == nil, "renaming to itself is fine")
    }

    @Test func aNewGridIsShownEmptyAndNewPanesJoinIt() {
        var (doc, project, panes) = sample()
        let grid = doc.createGrid(named: "Review", in: project)
        #expect(doc.project(project)?.shownGridID == grid)
        #expect(doc.project(project)?.visiblePanes.isEmpty == true)
        let added = doc.addPane(to: project, tab: PaneTab(agent: "shell"))
        #expect(doc.project(project)?.visiblePanes.map(\.id) == added.map { [$0] })
        doc.activateGrid(nil, in: project)
        #expect(doc.project(project)?.visiblePanes.map(\.id) == panes)
    }

    @Test func eachGridKeepsItsOwnLayout() {
        var (doc, project, _) = sample()
        doc.setLayoutMode(.spotlight, for: project)
        let grid = doc.createGrid(named: "Review", in: project)
        #expect(doc.project(project)?.layout == .auto, "a new grid starts in Auto")
        doc.setLayoutMode(.sidebar, for: project)
        doc.activateGrid(nil, in: project)
        #expect(doc.project(project)?.layout == .spotlight)
        doc.activateGrid(grid, in: project)
        #expect(doc.project(project)?.layout == .sidebar)
        #expect(doc.project(project)?.weightsKey == "\(project.rawValue):\(grid!.rawValue)")
    }

    @Test func movingAPaneAndRevealingIt() {
        var (doc, project, panes) = sample()
        let grid = doc.createGrid(named: "Review", in: project)
        doc.activateGrid(nil, in: project)
        doc.movePane(panes[1], toGrid: grid)
        #expect(doc.project(project)?.visiblePanes.map(\.id) == [panes[0]])
        doc.activateTab(try! #require(doc.pane(panes[1])?.pane.tabs.first?.id))
        #expect(doc.project(project)?.shownGridID == grid, "activating a hidden pane's tab shows its grid")
    }

    @Test func deletingKeepsOrClosesPanes() {
        var (doc, project, panes) = sample()
        let created = doc.createGrid(named: "Review", in: project)
        let grid = try! #require(created)
        doc.movePane(panes[0], toGrid: grid)
        doc.deleteGrid(grid, in: project, closingPanes: false)
        #expect(doc.project(project)?.grids == nil)
        #expect(doc.project(project)?.visiblePanes.count == 2, "kept panes go back to the main grid")
        let createdSecond = doc.createGrid(named: "Scratch", in: project)
        let second = try! #require(createdSecond)
        doc.movePane(panes[1], toGrid: second)
        doc.deleteGrid(second, in: project, closingPanes: true)
        #expect(doc.project(project)?.panes.map(\.id) == [panes[0]])
    }

    @Test func olderPanesAndProjectsDecodeWithoutGrids() throws {
        let pane = try JSONDecoder().decode(Pane.self, from: Data(#"{"id":"x","content":{"kind":"terminal"},"tabs":[]}"#.utf8))
        #expect(pane.gridID == nil)
    }
}
