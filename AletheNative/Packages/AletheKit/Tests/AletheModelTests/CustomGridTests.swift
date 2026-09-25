import CoreGraphics
import Foundation
import Testing
@testable import AletheModel

/// Port of upstream `gridLayout.test.ts`, plus presets, geometry and the document operations (P2-19).
@Suite struct CustomGridTests {
    private let ids = ["a", "b", "c"]

    /// 2×2 with three children: the bottom-right slot is free.
    private func threeInFour() -> CustomGrid {
        CustomGrid(cols: 2, rows: 2, cells: [
            "a": GridCell(col: 1, row: 1), "b": GridCell(col: 2, row: 1), "c": GridCell(col: 1, row: 2),
        ])
    }

    @Test func autoFillsRowByRow() {
        let layout = CustomGrid.auto(ids)
        #expect(layout.cols == 2 && layout.rows == 2)
        #expect(layout.cells["c"] == GridCell(col: 1, row: 2))
        #expect(CustomGrid.auto([]).rows == 1)
        let three = CustomGrid.auto(["a", "b", "c", "d"], cols: 3)
        #expect(three.rows == 2 && three.cells["d"] == GridCell(col: 1, row: 2))
    }

    @Test func reconcilePlacesMissingAndCollidingChildren() {
        let empty = CustomGrid(cols: 2, rows: 1).reconciled(["a", "b"])
        #expect(Set(empty.cells.values.map { "\($0.row):\($0.col)" }).count == 2)
        let colliding = CustomGrid(cols: 2, rows: 1, cells: ["a": GridCell(col: 1, row: 1), "b": GridCell(col: 1, row: 1)])
            .reconciled(["a", "b"])
        #expect(colliding.cells["a"] == GridCell(col: 1, row: 1))
        #expect(colliding.cells["b"] != GridCell(col: 1, row: 1))
    }

    @Test func reconcileAddsRowsWhenFull() {
        let layout = CustomGrid(cols: 2, rows: 1, cells: [
            "a": GridCell(col: 1, row: 1, colSpan: 2), "b": GridCell(col: 1, row: 1, colSpan: 2),
        ]).reconciled(["a", "b"])
        #expect(layout.rows >= 2 && layout.cells["b"]?.row == 2)
    }

    @Test func reconcileClampsAndRepairsBadValues() throws {
        let clamped = CustomGrid(cols: 2, rows: 2, cells: ["a": GridCell(col: 99, row: 99, colSpan: 99, rowSpan: 99)])
            .reconciled(["a"])
        let cell = try #require(clamped.cells["a"])
        #expect(cell.col >= 1 && cell.row >= 1 && cell.col + cell.colSpan - 1 <= clamped.cols)
        let zero = CustomGrid(cols: 0, rows: 0).reconciled(["a"])
        #expect(zero.cols >= 1 && zero.rows >= 1 && zero.cells["a"] != nil)
    }

    @Test func reconcileKeepsColumnSizesOnlyWhenTheyMatch() {
        #expect(CustomGrid(cols: 2, rows: 1, colSizes: [1, 2]).reconciled([]).colSizes == [1, 2])
        #expect(CustomGrid(cols: 2, rows: 1, colSizes: [1]).reconciled([]).colSizes == nil)
    }

    @Test func occupancyAndFreeCells() {
        #expect(threeInFour().occupancy(ids) == [["a", "b"], ["c", nil]])
        #expect(threeInFour().freeCells(ids).map { [$0.col, $0.row] } == [[2, 2]])
        #expect(threeInFour().hasFreeCells(ids))
        #expect(!CustomGrid.auto(["a", "b"]).hasFreeCells(["a", "b"]))
    }

    @Test func freeSpanCountsWholeFreeLines() {
        #expect(threeInFour().freeSpan(ids, "c", .right) == 1)
        #expect(threeInFour().freeSpan(ids, "b", .bottom) == 1)
        #expect(threeInFour().freeSpan(ids, "c", .top) == 0)
        #expect(threeInFour().freeSpan(ids, "a", .left) == 0)
        #expect(threeInFour().freeSpan(ids, "a", .right) == 0)
        let blocked = CustomGrid(cols: 2, rows: 3, cells: ["a": GridCell(col: 1, row: 1, colSpan: 2), "b": GridCell(col: 1, row: 2)])
        #expect(blocked.freeSpan(["a", "b"], "a", .bottom) == 0, "the whole line must be free")
    }

    @Test func expandGrowsAndShrinks() {
        #expect(threeInFour().expanding(ids, "c", .right, by: 5).cells["c"] == GridCell(col: 1, row: 2, colSpan: 2))
        let right = CustomGrid(cols: 2, rows: 1, cells: ["a": GridCell(col: 2, row: 1)])
        #expect(right.expanding(["a"], "a", .left, by: 1).cells["a"] == GridCell(col: 1, row: 1, colSpan: 2))
        let grown = threeInFour().expanding(ids, "c", .right, by: 1)
        #expect(grown.expanding(ids, "c", .right, by: -1).cells["c"]?.colSpan == 1)
        #expect(grown.expanding(ids, "c", .right, by: -9).cells["c"]?.colSpan == 1)
        #expect(threeInFour().expanding(ids, "a", .right, by: 1) == threeInFour())
    }

    @Test func fillFreeSpaceTakesWhatIsReachable() {
        let filled = threeInFour().fillingFreeSpace(ids, "c")
        #expect(filled.cells["c"] == GridCell(col: 1, row: 2, colSpan: 2))
        #expect(!filled.hasFreeCells(ids))
        let two = CustomGrid(cols: 2, rows: 2, cells: ["a": GridCell(col: 1, row: 1), "b": GridCell(col: 2, row: 1)])
            .fillingFreeSpace(["a", "b"], "b")
        #expect(two.cells["b"] == GridCell(col: 2, row: 1, rowSpan: 2) && two.cells["a"] == GridCell(col: 1, row: 1))
        let alone = CustomGrid(cols: 2, rows: 2, cells: ["a": GridCell(col: 2, row: 2)]).fillingFreeSpace(["a"], "a")
        #expect(alone.cells["a"] == GridCell(col: 1, row: 1, colSpan: 2, rowSpan: 2))
    }

    @Test func movingIntoFreeSlotsAndSwapping() {
        let moved = threeInFour().moving(ids, "c", toCol: 2, row: 2)
        #expect(moved.cells["c"] == GridCell(col: 2, row: 2) && moved.cells["b"] == GridCell(col: 2, row: 1))
        let swapped = threeInFour().moving(ids, "c", toCol: 2, row: 1)
        #expect(swapped.cells["c"] == GridCell(col: 2, row: 1) && swapped.cells["b"] == GridCell(col: 1, row: 2))
        let wide = CustomGrid(cols: 2, rows: 2, cells: [
            "a": GridCell(col: 1, row: 1, colSpan: 2), "b": GridCell(col: 1, row: 2), "c": GridCell(col: 2, row: 2),
        ]).moving(ids, "a", toCol: 1, row: 2)
        #expect(wide.cells["a"] == GridCell(col: 1, row: 2) && wide.cells["b"] == GridCell(col: 1, row: 1))
        #expect(threeInFour().moving(ids, "a", toCol: 1, row: 1) == threeInFour())
    }

    @Test func presetsMatchUpstream() {
        #expect(CustomGridPreset.balanced.layout(["a", "b", "c", "d", "e"]).cols == 3)
        #expect(CustomGridPreset.rows.layout(ids).cols == 1)
        let focus = CustomGridPreset.focusLeft.layout(ids)
        #expect(focus.cols == 2 && focus.rows == 2 && focus.cells["a"] == GridCell(col: 1, row: 1, rowSpan: 2))
        let top = CustomGridPreset.focusTop.layout(ids)
        #expect(top.cells["a"] == GridCell(col: 1, row: 1, colSpan: 2) && top.cells["c"] == GridCell(col: 2, row: 2))
    }

    @Test func geometryPlacesSpansAndOnlySeparatingDividers() {
        let grid = CustomGrid(cols: 2, rows: 2, cells: ["a": GridCell(col: 1, row: 1, colSpan: 2), "b": GridCell(col: 1, row: 2)])
        let geometry = PaneGridGeometry(count: 2, in: CGRect(x: 0, y: 0, width: 410, height: 310), weights: GridWeights(),
                                        gap: 10, handle: 6, mode: .grid, grid: grid, ids: ["a", "b"])
        #expect(geometry.paneFrames[0] == CGRect(x: 0, y: 0, width: 410, height: 150))
        #expect(geometry.paneFrames[1] == CGRect(x: 0, y: 160, width: 200, height: 150))
        #expect(geometry.freeSlots.map { [$0.col, $0.row] } == [[2, 2]])
        #expect(geometry.dividers[.gridColumn(boundary: 0, segment: 0)]?.minY == 160, "not across the spanning pane")
        #expect(geometry.dividers[.gridRow(boundary: 0, segment: 0)]?.width == 410)
    }

    @Test func savingSwitchesToGridAndRemembersIt() {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "p", folder: "/p")
        let panes = (0..<3).compactMap { _ in doc.addPane(to: project, tab: PaneTab(agent: "shell")) }
        let rows = CustomGridPreset.rows.layout(panes.map(\.rawValue))
        doc.setGridLayout(rows, for: project, recordHistory: true)
        doc.setGridLayout(rows, for: project, recordHistory: true)
        #expect(doc.project(project)?.layout == .grid)
        #expect(doc.project(project)?.gridLayoutHistory?.count == 1, "the same grid is remembered once")
        doc.moveGridCell(panes[2], toCol: 1, row: 1)
        #expect(doc.project(project)?.gridLayout?.cells[panes[2].rawValue]?.row == 1)
        doc.setTrackWeights(GridWeights(columns: [1], rows: [0.5, 0.25, 0.25]), for: project)
        #expect(doc.project(project)?.gridLayout?.rowSizes == [0.5, 0.25, 0.25])
        #expect(doc.workspace.gridWeights[project.rawValue] == nil, "grid sizes live in the grid")
    }
}
