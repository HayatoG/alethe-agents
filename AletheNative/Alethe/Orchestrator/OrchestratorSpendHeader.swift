import AletheOrchestrator
import SwiftUI

/// The board header's spend per agent for the selected planner and the quota warning chips. P6-17
/// fills this in (`AgentSpend.aggregate(jobs)`, the usage feed); `jobs` are the selected planner's.
struct OrchestratorSpendHeader: View {
    let jobs: [JobSnapshot]

    var body: some View {
        EmptyView()
    }
}
