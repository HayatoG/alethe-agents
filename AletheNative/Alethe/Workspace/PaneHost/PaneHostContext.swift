import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// What the AppKit pane host needs from the SwiftUI side: the environment, the current look, and
/// the undoable edits it triggers.
@MainActor
struct PaneHostContext {
    let environment: AppEnvironment
    let theme: Theme
    let metrics: Metrics
    let undoManager: () -> UndoManager?

    var workspace: WorkspaceModel? { environment.workspace }

    /// A SwiftUI view with the environment every Alethe view expects.
    func hosted(_ view: some View) -> AnyView {
        AnyView(view
            .environment(environment)
            .environment(\.theme, theme)
            .environment(\.metrics, metrics))
    }

    func closePane(_ pane: PaneID) {
        workspace?.update(undoManager: undoManager(), actionName: String(localized: "undo.closeTerminal")) {
            $0.closePane(pane)
        }
    }

    func closeContainer(_ project: ProjectID) {
        workspace?.update(undoManager: undoManager(), actionName: String(localized: "undo.closeProject")) {
            $0.close(project)
        }
    }

    func swapPanes(_ first: PaneID, _ second: PaneID) {
        workspace?.update(undoManager: undoManager(), actionName: String(localized: "undo.move")) {
            $0.swapPanes(first, second)
        }
    }

    /// Clicking a pane focuses it and selects its project; not undoable (navigation, not an edit).
    func focus(_ pane: PaneID, in project: ProjectID) {
        guard let doc = workspace?.document,
              doc.workspace.focusedPaneID != pane || doc.workspace.selectedProjectID != project else { return }
        workspace?.update {
            $0.workspace.focusedPaneID = pane
            $0.workspace.selectedProjectID = project
        }
    }

    /// Resizes are committed once, on release; not undoable (like upstream).
    func setContainerWeights(_ weights: [Double]) {
        workspace?.update { $0.workspace.containerWeights = weights }
    }

    func setGridWeights(_ weights: GridWeights, for project: ProjectID) {
        workspace?.update { $0.workspace.gridWeights[project.rawValue] = weights }
    }
}
