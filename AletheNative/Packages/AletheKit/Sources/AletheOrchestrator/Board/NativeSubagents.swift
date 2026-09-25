import Foundation
import AletheAgents
import AletheIntegrations

/// A planner's own subagent, teammate or background shell as its hooks describe it (the fields of
/// upstream `AgentNode` the board reads). The tracker that fills these lives in the app (P6-11).
public struct NativeSubagent: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case subagent
        case teammate
        case background
    }

    public enum Status: String, Hashable, Sendable {
        case running
        case idle
        case done
    }

    public var id: String
    public var agentType: String
    public var kind: Kind
    /// The terminal it belongs to; nil when the hook carried none.
    public var plannerID: String?
    /// Which CLI spawned it (`claude`, `codex`).
    public var sourceAgent: String
    /// The prompt of the tool call that created it. User data.
    public var prompt: String?
    public var status: Status
    /// Milliseconds since 1970.
    public var startedAt: UInt64
    public var endedAt: UInt64?
    public var result: String?

    public init(
        id: String,
        agentType: String,
        kind: Kind = .subagent,
        plannerID: String?,
        sourceAgent: String = WorkerAgent.claude,
        prompt: String? = nil,
        status: Status = .running,
        startedAt: UInt64,
        endedAt: UInt64? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.kind = kind
        self.plannerID = plannerID
        self.sourceAgent = sourceAgent
        self.prompt = prompt
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result
    }
}

public enum NativeSubagents {
    public static let runLabel = "Subagents"

    public static func runID(plannerID: String?) -> String {
        "native-subagents:" + (plannerID ?? "none")
    }

    /// Upstream `nativeSubagentJobs`: subagents reshaped as job snapshots, so they land on the same
    /// planner tree as delegated workers, in one shared run per planner. `costs` is the transcript
    /// spend by node id; a background shell never carries agent spend. There is no routing note:
    /// Alethe never picked an agent for these, the planner spawned them in its own process.
    public static func jobs(_ nodes: [NativeSubagent], costs: [String: SessionCost] = [:], nowMs: UInt64) -> [JobSnapshot] {
        nodes.map { node in
            let cost = node.kind == .background ? nil : costs[node.id]
            let end = node.endedAt ?? nowMs
            let elapsedMs = end >= node.startedAt ? Double(end - node.startedAt) : -Double(node.startedAt - end)
            let tokens: OrderedJSON? = cost.map { cost in
                [
                    "total": [
                        "totalTokens": .integer(cost.totalTokens),
                        "inputTokens": .integer(cost.input),
                        "outputTokens": .integer(cost.output),
                        "cachedInputTokens": .integer(cost.cacheRead),
                        "cacheCreationInputTokens": .integer(cost.cacheWrite),
                    ],
                ]
            }
            return JobSnapshot(
                id: node.id.contains(":") ? node.id : "subagent:" + node.id,
                plannerID: node.plannerID,
                agent: node.sourceAgent,
                runID: runID(plannerID: node.plannerID),
                runLabel: runLabel,
                spec: node.prompt ?? node.agentType,
                cwd: "",
                status: node.status == .running ? .running : .done,
                outcome: node.result,
                seconds: jsRound(elapsedMs / 1000),
                tokens: tokens,
                costUSD: cost?.costUSD,
                summary: node.result ?? node.prompt ?? node.agentType,
                native: true
            )
        }
    }
}
