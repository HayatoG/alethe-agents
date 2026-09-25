import Foundation
import Testing
import AletheAgents
@testable import AletheOrchestrator

/// Planner subagents from hooks (P6-11, upstream `agentCanvasStore.ingest`).
@Suite struct SubagentLedgerTests {
    private func hook(_ json: String) throws -> SubagentHook {
        try #require(SubagentHook.parse(Data(json.utf8)))
    }

    @Test func aSubagentTakesTheOldestPromptOfItsTypeAndFinishes() throws {
        var ledger = SubagentLedger()
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"Find the parser","prompt":"Look for it"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 0)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"Second"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 0)
        let started = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore"}"#),
                                    planner: "pty-1", sourceAgent: "claude", nowMs: 1_000)
        #expect(started.changed)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"Explore"}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 1_000)
        #expect(ledger.nodes.map(\.prompt) == ["Find the parser", "Second"])
        #expect(ledger.nodes.allSatisfy { $0.status == .running && $0.plannerID == "pty-1" && $0.kind == .subagent })

        let stopped = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStop","agent_id":"a1","last_assistant_message":"Found it","agent_transcript_path":"/t/a1.jsonl"}"#),
                                    planner: "pty-1", sourceAgent: "claude", nowMs: 4_000)
        #expect(stopped.transcript == SubagentLedger.Transcript(nodeID: "a1", path: "/t/a1.jsonl"))
        #expect(ledger.nodes[0].status == .done && ledger.nodes[0].endedAt == 4_000 && ledger.nodes[0].result == "Found it")
        let jobs = NativeSubagents.jobs(ledger.nodes, nowMs: 5_000)
        #expect(jobs.map(\.id) == ["subagent:a1", "subagent:a2"])
        #expect(jobs.map(\.seconds) == [3, 4])
    }

    @Test func promptsWaitWithinTheirOwnPlanner() throws {
        var ledger = SubagentLedger()
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Mine"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 0)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"b1","agent_type":"general-purpose"}"#),
                          planner: "pty-2", sourceAgent: "claude", nowMs: 0)
        #expect(ledger.nodes.first?.prompt == nil)
        #expect(ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"b1"}"#),
                              planner: "pty-2", sourceAgent: "claude", nowMs: 0) == .none, "a start is counted once")
    }

    @Test func teammatesAreOneNodeAcrossTheirTurns() throws {
        var ledger = SubagentLedger()
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"name":"reviewer","team_name":"squad","prompt":"Review"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 0)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"i1","agent_type":"reviewer"}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 1)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStop","agent_id":"i1"}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 2)
        #expect(ledger.nodes.count == 1)
        #expect(ledger.nodes[0].id == "teammate:pty-1/reviewer" && ledger.nodes[0].kind == .teammate)
        #expect(ledger.nodes[0].status == .idle && ledger.nodes[0].prompt == "Review")
        _ = ledger.ingest(try hook(#"{"hook_event_name":"SubagentStart","agent_id":"i2","agent_type":"reviewer"}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 3)
        #expect(ledger.nodes.count == 1 && ledger.nodes[0].status == .running)
        _ = ledger.ingest(try hook(#"{"hook_event_name":"TeammateIdle","teammate_name":"reviewer"}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 4)
        #expect(ledger.nodes[0].status == .idle)
        #expect(NativeSubagents.jobs(ledger.nodes, nowMs: 5).first?.id == "teammate:pty-1/reviewer")
    }

    @Test func backgroundShellsRunUntilTheyAreStopped() throws {
        var ledger = SubagentLedger()
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm run dev","run_in_background":true},"tool_response":{"backgroundTaskId":"sh1"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 0)
        #expect(ledger.nodes.first?.id == "background:sh1" && ledger.nodes.first?.kind == .background)
        #expect(ledger.nodes.first?.prompt == "npm run dev")
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PostToolUse","tool_name":"KillShell","tool_input":{"shell_id":"sh1"},"tool_response":{"message":"Killed"}}"#),
                          planner: "pty-1", sourceAgent: "claude", nowMs: 9)
        #expect(ledger.nodes.first?.status == .done && ledger.nodes.first?.result == "Killed")
        // A subagent's own tool call is not the planner's shell.
        #expect(ledger.ingest(try hook(#"{"hook_event_name":"PostToolUse","agent_id":"a1","tool_name":"Bash","tool_input":{"run_in_background":true},"tool_response":{"backgroundTaskId":"sh2"}}"#),
                              planner: "pty-1", sourceAgent: "claude", nowMs: 10) == .none)
    }

    @Test func aToolCallFromAnUnseenSubagentShowsIt() throws {
        var ledger = SubagentLedger()
        _ = ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","agent_id":"x1","agent_type":"Plan","tool_name":"Read"}"#),
                          planner: "pty-3", sourceAgent: "codex", nowMs: 7)
        #expect(ledger.nodes == [NativeSubagent(id: "x1", agentType: "Plan", plannerID: "pty-3", sourceAgent: "codex", startedAt: 7)])
        #expect(ledger.ingest(try hook(#"{"hook_event_name":"PreToolUse","agent_id":"x1","tool_name":"Grep"}"#),
                              planner: "pty-3", sourceAgent: "codex", nowMs: 8) == .none)
    }
}
