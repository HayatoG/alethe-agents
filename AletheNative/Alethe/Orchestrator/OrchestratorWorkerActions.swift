import AletheModel
import AletheOrchestrator
import SwiftUI

/// The selected worker's actions, at the end of its detail on the board. P6-15 fills this in:
/// the pending ask (Accept, Accept for Session, Decline, Abort), the steer/send field
/// (`OrchestratorService.message(steer:)`), the diff (`OrchestratorService.diff`), Cancel, Release
/// and Show in Finder. A native subagent (`job.native`) has no worker to act on.
struct OrchestratorWorkerActions: View {
    let job: JobSnapshot
    let project: ProjectID
    let board: OrchestratorBoardModel
    let units: BoardUnits

    var body: some View {
        EmptyView()
    }
}
