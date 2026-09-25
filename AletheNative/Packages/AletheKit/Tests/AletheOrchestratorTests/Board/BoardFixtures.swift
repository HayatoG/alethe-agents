import Foundation
import AletheIntegrations
@testable import AletheOrchestrator

/// The upstream tests' `job()` builder: a running Codex worker with nothing reported yet.
func boardJob(
    _ id: String,
    run runID: String,
    planner plannerID: String? = nil,
    agent: String = "codex",
    label runLabel: String? = nil,
    status: JobStatus = .running,
    tokens: OrderedJSON? = nil,
    costUSD: Double? = nil,
    routing: OrderedJSON? = nil,
    summary: String = ""
) -> JobSnapshot {
    JobSnapshot(
        id: id,
        plannerID: plannerID,
        agent: agent,
        runID: runID,
        runLabel: runLabel,
        spec: "spec",
        cwd: "/repo",
        status: status,
        tokens: tokens,
        costUSD: costUSD,
        routing: routing,
        summary: summary
    )
}

func counts(
    blocked: Int = 0,
    running: Int = 0,
    queued: Int = 0,
    interrupted: Int = 0,
    failed: Int = 0,
    finished: Int = 0
) -> RunCounts {
    RunCounts([
        .blocked: blocked, .running: running, .queued: queued,
        .interrupted: interrupted, .failed: failed, .finished: finished,
    ])
}
