import AletheAgents
import AletheOrchestrator
import Foundation
import Observation

/// The planners' own subagents and teammates for the board (P6-11; upstream `agentCanvasStore` fed
/// by `useAgentHookBridge`, with `nodeCostStore`): nodes per planner tab from the hook bridge, each
/// finished node's spend read from its transcript (P3-8), and all of them as job snapshots in one
/// "Subagents" run per planner (`nativeSubagentJobs`).
@Observable
@MainActor
final class SubagentTracker {
    private(set) var ledger = SubagentLedger()
    /// Transcript spend by node id.
    private(set) var costs: [String: SessionCost] = [:]

    var nodes: [NativeSubagent] { ledger.nodes }

    /// Job snapshots for the board, alongside the orchestrator's own workers.
    func jobs(now: Date = Date()) -> [JobSnapshot] {
        NativeSubagents.jobs(ledger.nodes, costs: costs, nowMs: UInt64(max(0, now.timeIntervalSince1970 * 1000)))
    }

    /// One hook from a planner tab; `sourceAgent` is the CLI that fired it.
    func ingest(_ hook: SubagentHook, planner: String, sourceAgent: String, now: Date = Date()) {
        let outcome = ledger.ingest(hook, planner: planner, sourceAgent: sourceAgent,
                                    nowMs: UInt64(max(0, now.timeIntervalSince1970 * 1000)))
        guard let transcript = outcome.transcript else { return }
        readCost(transcript, sourceAgent: sourceAgent)
    }

    private func readCost(_ transcript: SubagentLedger.Transcript, sourceAgent: String) {
        let path = transcript.path
        // The path comes from the hook body: only an absolute JSONL transcript is read.
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return }
        Task { [weak self] in
            let cost = await Task.detached(priority: .utility) {
                sourceAgent == WorkerAgent.codex ? SessionCosts.codex(rollout: path) : SessionCosts.claude(transcript: path)
            }.value
            guard let self, self.ledger.nodes.contains(where: { $0.id == transcript.nodeID }) else { return }
            self.costs[transcript.nodeID] = cost
        }
    }
}
