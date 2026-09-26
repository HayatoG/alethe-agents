import AletheModel
import AletheOrchestrator
import SwiftUI

/// Applying a finished worker's worktree into the project's branch, on the worker detail. P6-16
/// fills this in (`ApplyWorktree`); shown for a done worker with a `worktree`.
struct OrchestratorApplyAction: View {
    let job: JobSnapshot
    let project: ProjectID
    let board: OrchestratorBoardModel
    let units: BoardUnits

    var body: some View {
        EmptyView()
    }
}
