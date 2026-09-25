import Foundation
import AletheAgents

/// The planners' own subagents, teammates and background shells, built from their hooks (the node
/// part of upstream `agentCanvasStore.ingest`). Unlike upstream's single global store, pending
/// prompts and teammates are matched within the planner tab that fired the hook. The tool feed and
/// team tasks are not kept: the board does not show them.
public struct SubagentLedger: Sendable {
    /// What an event changed.
    public struct Outcome: Equatable, Sendable {
        public var changed: Bool
        /// A node whose transcript is now known, so its spend can be read.
        public var transcript: Transcript?

        public static let none = Outcome(changed: false)

        public init(changed: Bool, transcript: Transcript? = nil) {
            self.changed = changed
            self.transcript = transcript
        }
    }

    public struct Transcript: Equatable, Sendable {
        public var nodeID: String
        public var path: String

        public init(nodeID: String, path: String) {
            self.nodeID = nodeID
            self.path = path
        }
    }

    private struct PendingPrompt: Sendable {
        var description: String?
        var prompt: String?
    }

    /// Upstream caps each type's queue.
    static let pendingLimit = 32
    static let spawnerTools: Set<String> = ["Agent", "Task"]

    public private(set) var nodes: [NativeSubagent] = []
    /// Transcript paths by node id, from `SubagentStop`.
    public private(set) var transcripts: [String: String] = [:]
    private var pending: [PendingKey: [PendingPrompt]] = [:]
    /// Each teammate incarnation's agent id → its aggregate node id.
    private var incarnations: [String: String] = [:]

    private struct PendingKey: Hashable, Sendable {
        var planner: String?
        var agentType: String
    }

    public init() {}

    public mutating func ingest(_ hook: SubagentHook, planner: String?, sourceAgent: String, nowMs: UInt64) -> Outcome {
        switch hook.event {
        case "SubagentStart": return start(hook, planner: planner, sourceAgent: sourceAgent, nowMs: nowMs)
        case "SubagentStop": return stop(hook, nowMs: nowMs)
        case "PostToolUse" where hook.agentID == nil: return postToolUse(hook, planner: planner, sourceAgent: sourceAgent, nowMs: nowMs)
        case "PreToolUse": return preToolUse(hook, planner: planner, sourceAgent: sourceAgent, nowMs: nowMs)
        case "TeammateIdle": return teammateIdle(hook, planner: planner)
        default: return .none
        }
    }

    private func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    private mutating func start(_ hook: SubagentHook, planner: String?, sourceAgent: String, nowMs: UInt64) -> Outcome {
        guard let id = hook.agentID, index(of: id) == nil else { return .none }
        let agentType = hook.agentType ?? "unknown"
        // A teammate's next turn arrives as a new subagent of its name: it is the same node again.
        if let teammate = nodes.firstIndex(where: { $0.kind == .teammate && $0.plannerID == planner && $0.agentType == agentType }) {
            nodes[teammate].status = .running
            incarnations[id] = nodes[teammate].id
            return Outcome(changed: true)
        }
        // The oldest prompt waiting for this type is this subagent's (FIFO).
        let key = PendingKey(planner: planner, agentType: agentType)
        let prompt = pending[key]?.first
        if prompt != nil { pending[key]?.removeFirst() }
        nodes.append(NativeSubagent(id: id, agentType: agentType, plannerID: planner, sourceAgent: sourceAgent,
                                    prompt: prompt?.description ?? prompt?.prompt, startedAt: nowMs))
        return Outcome(changed: true)
    }

    private mutating func stop(_ hook: SubagentHook, nowMs: UInt64) -> Outcome {
        guard let id = hook.agentID else { return .none }
        let nodeID = incarnations[id] ?? id
        guard let index = index(of: nodeID) else { return .none }
        nodes[index].status = nodes[index].kind == .teammate ? .idle : .done
        nodes[index].endedAt = nowMs
        if let message = hook.lastAssistantMessage { nodes[index].result = message }
        incarnations[id] = nil
        guard let path = hook.transcriptPath else { return Outcome(changed: true) }
        transcripts[nodeID] = path
        return Outcome(changed: true, transcript: Transcript(nodeID: nodeID, path: path))
    }

    private mutating func postToolUse(_ hook: SubagentHook, planner: String?, sourceAgent: String, nowMs: UInt64) -> Outcome {
        // A shell the planner left running (`run_in_background`) gets no SubagentStart/Stop of its
        // own; it stays running until the planner stops it.
        if hook.toolName == "Bash", hook.runInBackground {
            guard let task = hook.response["backgroundTaskId"] else { return .none }
            let id = "background:" + task
            guard index(of: id) == nil else { return .none }
            nodes.append(NativeSubagent(id: id, agentType: "Bash", kind: .background, plannerID: planner,
                                        sourceAgent: sourceAgent, prompt: hook.input["description"] ?? hook.input["command"],
                                        startedAt: nowMs))
            return Outcome(changed: true)
        }
        if hook.toolName == "TaskStop" || hook.toolName == "KillShell" {
            guard let task = hook.input["task_id"] ?? hook.input["shell_id"],
                  let index = index(of: "background:" + task) else { return .none }
            nodes[index].status = .done
            nodes[index].endedAt = nowMs
            if let message = hook.response["message"] { nodes[index].result = message }
            return Outcome(changed: true)
        }
        return .none
    }

    private mutating func preToolUse(_ hook: SubagentHook, planner: String?, sourceAgent: String, nowMs: UInt64) -> Outcome {
        guard let agentID = hook.agentID else {
            guard let tool = hook.toolName, Self.spawnerTools.contains(tool) else { return .none }
            // A teammate spawn names the teammate and its team; a plain subagent does not.
            if let name = hook.input["name"], hook.input["team_name"] != nil {
                let id = teammateID(name, planner: planner)
                guard index(of: id) == nil else { return .none }
                nodes.append(NativeSubagent(id: id, agentType: name, kind: .teammate, plannerID: planner,
                                            sourceAgent: sourceAgent, prompt: hook.input["prompt"] ?? hook.input["description"],
                                            startedAt: nowMs))
                return Outcome(changed: true)
            }
            let key = PendingKey(planner: planner, agentType: hook.input["subagent_type"] ?? "general-purpose")
            let queue = (pending[key] ?? []) + [PendingPrompt(description: hook.input["description"], prompt: hook.input["prompt"])]
            pending[key] = Array(queue.suffix(Self.pendingLimit))
            return .none
        }
        // A tool call from a subagent whose start was missed still shows it (upstream `ensureNode`).
        guard index(of: incarnations[agentID] ?? agentID) == nil else { return .none }
        nodes.append(NativeSubagent(id: agentID, agentType: hook.agentType ?? "unknown", plannerID: planner,
                                    sourceAgent: sourceAgent, startedAt: nowMs))
        return Outcome(changed: true)
    }

    private mutating func teammateIdle(_ hook: SubagentHook, planner: String?) -> Outcome {
        guard let name = hook.teammateName,
              let index = nodes.firstIndex(where: { $0.kind == .teammate && $0.plannerID == planner && $0.agentType == name }),
              nodes[index].status != .idle else { return .none }
        nodes[index].status = .idle
        return Outcome(changed: true)
    }

    /// Upstream's `teammate:<name>`, qualified by the planner so two planners' teammates of the same
    /// name stay two nodes (the id doubles as the job id).
    func teammateID(_ name: String, planner: String?) -> String {
        planner.map { "teammate:\($0)/\(name)" } ?? "teammate:" + name
    }
}
