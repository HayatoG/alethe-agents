import AletheFoundation
import AletheGit
import AletheIntegrations
import Foundation

/// Where a scheduled task stands (upstream `TaskStatus`, camelCase in JSON).
public enum SchedulerTaskStatus: String, Hashable, Sendable, CaseIterable, Codable {
    case pending, ready, running, completed, failed, blocked

    /// Kept across a reload even when its `task.md` line is gone.
    var survivesReload: Bool { self == .running || self == .completed || self == .failed }
}

/// One roadmap item of a project's `.planning/task.md` (upstream `Task`).
public struct SchedulerTask: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var projectID: String
    public var title: String
    public var dependencies: [String]
    public var status: SchedulerTaskStatus
    public var assignedAgentID: String?
    public var leaseResource: String?
    /// The provisioned worktree whose `.planning/` decides when the task is done.
    public var worktreePath: String?
    public var priority: Int

    public init(id: String, projectID: String, title: String, dependencies: [String] = [],
                status: SchedulerTaskStatus = .pending, assignedAgentID: String? = nil,
                leaseResource: String? = nil, worktreePath: String? = nil, priority: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.dependencies = dependencies
        self.status = status
        self.assignedAgentID = assignedAgentID
        self.leaseResource = leaseResource
        self.worktreePath = worktreePath
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case id, projectID = "projectId", title, dependencies, status
        case assignedAgentID = "assignedAgentId", leaseResource, worktreePath, priority
    }

    /// Upstream serializes absent values as `null`, not as missing keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(title, forKey: .title)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encode(status, forKey: .status)
        try container.encode(assignedAgentID, forKey: .assignedAgentID)
        try container.encode(leaseResource, forKey: .leaseResource)
        try container.encode(worktreePath, forKey: .worktreePath)
        try container.encode(priority, forKey: .priority)
    }
}

/// Scheduler event names (upstream's).
public enum SchedulerEvent {
    public static let taskReserved = "TaskReserved"
    public static let taskStarted = "TaskStarted"
    public static let agentSpawnRequested = "AgentSpawnRequested"
    public static let taskFailed = "TaskFailed"
    public static let taskCompleted = "TaskCompleted"
}

public enum SchedulerError: Error, Equatable {
    /// Upstream `repository_root` fails outside a git checkout.
    case notARepository
}

/// Runs a project's `.planning/task.md` roadmap as a chain of tasks (upstream `scheduler.rs`): each
/// item depends on the one before; a tick readies tasks whose dependencies are completed, starts
/// ready ones on a `worktree:<task>` lease with a provisioned worktree, and completes running ones
/// once their worktree's planning reports complete. State lives in memory, like upstream. Nothing
/// runs on its own: ticks happen on request, and on `PlanningUpdated` only after `startAutoTick`.
public actor Scheduler {
    public typealias Provisioner = @Sendable (_ repo: URL, _ agentID: String, _ mode: WorktreeMode) async throws -> WorktreeInfo
    public typealias PlanningReader = @Sendable (_ worktree: URL) -> PlanningStatus

    private let bus: EventBus?
    private let provision: Provisioner
    private let planningStatus: PlanningReader
    private let now: @Sendable () -> Date

    public private(set) var tasks: [String: SchedulerTask] = [:]
    public private(set) var leases: Set<String> = []
    private var modes: [String: WorktreeMode] = [:]
    private var autoTick: Task<Void, Never>?

    public init(
        bus: EventBus? = nil,
        provision: @escaping Provisioner = { repo, agentID, mode in
            try await GitWorktrees().provision(repo: repo, agentId: agentID, mode: mode)
        },
        planningStatus: @escaping PlanningReader = { PlanningGate.status(of: $0) },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.bus = bus
        self.provision = provision
        self.planningStatus = planningStatus
        self.now = now
    }

    /// Upstream `derive_item_task_id`: stable for a project and item text, never shared across
    /// projects. FNV-1a stands in for Rust's `DefaultHasher`; ids live only in memory.
    public static func taskID(projectID: String, text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(projectID)-gsd-\(String(hash, radix: 16))"
    }

    public func tasks(projectID: String) -> [SchedulerTask] {
        tasks.values.filter { $0.projectID == projectID }
    }

    public func worktreeMode(for projectID: String) -> WorktreeMode {
        modes[projectID] ?? .gitWorktree
    }

    public func setWorktreeMode(_ mode: WorktreeMode, for projectID: String) {
        modes[projectID] = mode
    }

    /// Test and restore seam: puts a task (and its lease) in place as is.
    public func insert(_ task: SchedulerTask) {
        tasks[task.id] = task
        if let lease = task.leaseResource { leases.insert(lease) }
    }

    // MARK: Loading

    /// Upstream `load_gsd_tasks`: rebuilds the project's chain from `.planning/task.md`. Running,
    /// completed and failed tasks keep their state (and survive a removed line); pending ones whose
    /// line is gone are dropped. A missing `task.md` changes nothing.
    public func load(projectID: String, repo: URL) throws {
        guard let root = PlanningGate.repositoryRoot(containing: repo) else { throw SchedulerError.notARepository }
        let file = PlanningGate.planningFolder(of: root).appending(path: "task.md")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }

        var fresh: [SchedulerTask] = []
        var previous: String?
        for item in PlanningGate.roadmapItems(content) where !item.text.isEmpty {
            let id = Self.taskID(projectID: projectID, text: item.text)
            fresh.append(SchedulerTask(id: id, projectID: projectID, title: item.text,
                                       dependencies: previous.map { [$0] } ?? [],
                                       status: item.checked ? .completed : .pending))
            previous = id
        }
        let freshIDs = Set(fresh.map(\.id))
        tasks = tasks.filter { id, task in
            task.projectID != projectID || freshIDs.contains(id) || task.status.survivesReload
        }
        for var task in fresh {
            if let existing = tasks[task.id], existing.status.survivesReload {
                task.status = existing.status
                task.assignedAgentID = existing.assignedAgentID
                task.leaseResource = existing.leaseResource
                task.worktreePath = existing.worktreePath
            }
            tasks[task.id] = task
        }
    }

    // MARK: Ticks

    /// Upstream `trigger_scheduler_tick`: remembers the project's worktree mode when given, reloads
    /// `task.md` (a failed reload still ticks, like upstream) and runs one tick.
    public func trigger(projectID: String, repo: URL, mode: WorktreeMode? = nil) async throws {
        if let mode { modes[projectID] = mode }
        try? load(projectID: projectID, repo: repo)
        try await tick(projectID: projectID, repo: repo)
    }

    /// Upstream `run_scheduler_tick`. Worktrees are provisioned concurrently and awaited, so a
    /// tick returns once every task it started has its worktree (or failed).
    public func tick(projectID: String, repo: URL) async throws {
        try Task.checkCancellation()

        // Pending -> ready when every dependency is completed.
        let toReady = tasks.values.filter { task in
            task.projectID == projectID && task.status == .pending
                && task.dependencies.allSatisfy { tasks[$0]?.status == .completed }
        }.map(\.id)
        for id in toReady {
            guard var task = tasks[id] else { continue }
            task.status = .ready
            tasks[id] = task
            await publish(SchedulerEvent.taskReserved, prefix: "sched", task: task)
        }

        // Ready -> running when its worktree lease is free.
        var started: [(id: String, agentID: String, title: String)] = []
        for task in tasks.values where task.projectID == projectID && task.status == .ready {
            let lease = "worktree:\(task.id)"
            guard !leases.contains(lease) else { continue }
            leases.insert(lease)
            var running = task
            let agentID = "agent-\(task.id)"
            running.status = .running
            running.assignedAgentID = agentID
            running.leaseResource = lease
            tasks[task.id] = running
            await publish(SchedulerEvent.taskStarted, prefix: "sched", task: running,
                          data: ["agent_id": .string(agentID)])
            started.append((task.id, agentID, task.title))
        }
        if !started.isEmpty {
            let mode = worktreeMode(for: projectID)
            let provision = provision
            await withTaskGroup(of: (String, String, String, Result<WorktreeInfo, any Error>).self) { group in
                for entry in started {
                    group.addTask {
                        do {
                            return (entry.id, entry.agentID, entry.title,
                                    .success(try await provision(repo, entry.agentID, mode)))
                        } catch {
                            return (entry.id, entry.agentID, entry.title, .failure(error))
                        }
                    }
                }
                for await (id, agentID, title, result) in group {
                    await provisioned(taskID: id, projectID: projectID, agentID: agentID, title: title, result: result)
                }
            }
        }

        // Running -> completed when its worktree's planning reports complete.
        let reader = planningStatus
        for task in tasks.values where task.projectID == projectID && task.status == .running {
            guard let path = task.worktreePath else { continue }
            let status = reader(URL(fileURLWithPath: path, isDirectory: true))
            guard status.hasPlanning, status.reportedComplete else { continue }
            var done = task
            done.status = .completed
            if let lease = done.leaseResource { leases.remove(lease) }
            done.leaseResource = nil
            tasks[task.id] = done
            await publish(SchedulerEvent.taskCompleted, prefix: "sched", task: done)
        }
    }

    private func provisioned(taskID: String, projectID: String, agentID: String, title: String,
                             result: Result<WorktreeInfo, any Error>) async {
        guard var task = tasks[taskID] else { return }
        switch result {
        case .success(let info):
            task.worktreePath = info.path
            tasks[taskID] = task
            // Unlike upstream, a task cancelled while provisioning asks for no agent.
            guard task.status == .running, task.assignedAgentID == agentID else { return }
            await publish(SchedulerEvent.agentSpawnRequested, prefix: "sched", task: task, data: [
                "agent_id": .string(agentID), "worktree_path": .string(info.path), "task_title": .string(title),
            ])
        case .failure(let error):
            // A cancel while provisioning already failed the task and published it.
            guard task.status == .running, task.assignedAgentID == agentID else { return }
            task.status = .failed
            if let lease = task.leaseResource { leases.remove(lease) }
            task.leaseResource = nil
            task.assignedAgentID = nil
            tasks[taskID] = task
            await publish(SchedulerEvent.taskFailed, prefix: "sched", task: task,
                          data: ["error": .string(String(describing: error))])
        }
    }

    // MARK: Cancel

    /// Upstream `cancel_task`: a running task fails and frees its lease; anything else is left as is.
    /// Returns whether the task was cancelled.
    @discardableResult
    public func cancel(taskID: String) async -> Bool {
        guard var task = tasks[taskID], task.status == .running else { return false }
        task.status = .failed
        task.assignedAgentID = nil
        if let lease = task.leaseResource { leases.remove(lease) }
        task.leaseResource = nil
        tasks[taskID] = task
        await publish(SchedulerEvent.taskFailed, prefix: "cancel", task: task,
                      data: ["reason": .string("Cancelled by user")])
        return true
    }

    // MARK: Auto tick

    /// Ticks a project whenever the bus reports its `.planning/` changed (upstream
    /// `start_scheduler_event_loop`: the project comes as the event's task id, the repository is
    /// the parent of `planning_dir`). Off until called.
    public func startAutoTick(on bus: EventBus) async {
        guard autoTick == nil else { return }
        let events = await bus.subscribe()
        autoTick = Task.detached { [weak self] in
            for await event in events {
                guard event.type == BusEventType.planningUpdated, let projectID = event.taskID,
                      case .object(let data) = event.data,
                      case .string(let planningDir)? = data["planning_dir"] else { continue }
                let repo = URL(fileURLWithPath: planningDir, isDirectory: true).deletingLastPathComponent()
                guard !repo.path.isEmpty, let self else { continue }
                try? await self.trigger(projectID: projectID, repo: repo)
            }
        }
    }

    public func stopAutoTick() {
        autoTick?.cancel()
        autoTick = nil
    }

    public var isAutoTicking: Bool { autoTick != nil }

    // MARK: Events

    /// Upstream publishes the project as the event's task id and the task as its agent id.
    private func publish(_ type: String, prefix: String, task: SchedulerTask, data: [String: JSONValue] = [:]) async {
        guard let bus else { return }
        await bus.publish(BusEvent(type: type, correlationID: BusEvent.correlationID(prefix: prefix),
                                   taskID: task.projectID, agentID: task.id, data: .object(data), date: now()))
    }
}
