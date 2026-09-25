import AletheFoundation
import AletheGit
import AletheIntegrations
import Foundation
import Testing
@testable import AletheOrchestrator

private func uniqueProjectID(_ label: String) -> String {
    "test-\(label)-\(UUID().uuidString)"
}

private func temporaryFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "alethe-scheduler-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A repository with one commit, like upstream's `temp_git_repo`.
private func temporaryGitRepo(_ label: String) async throws -> URL {
    let root = try temporaryFolder(label)
    let git = GitRunner()
    _ = try await git.run(["init", "-b", "main"], in: root)
    _ = try await git.run(["config", "user.name", "Alethe Test"], in: root)
    _ = try await git.run(["config", "user.email", "alethe@example.invalid"], in: root)
    _ = try await git.run(["config", "commit.gpgsign", "false"], in: root)
    try "a\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    _ = try await git.run(["add", "-A"], in: root)
    _ = try await git.run(["commit", "-m", "base"], in: root)
    return root
}

private func writeTaskList(_ content: String, in root: URL) throws {
    let folder = root.appending(path: ".planning", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try content.write(to: folder.appending(path: "task.md"), atomically: true, encoding: .utf8)
}

private struct ProvisionFailure: Error {}

/// A scheduler that never touches git: worktrees are folders under `base`.
private func stubScheduler(bus: EventBus? = nil, base: URL, failing: Bool = false) -> Scheduler {
    Scheduler(bus: bus, provision: { _, agentID, mode in
        if failing { throw ProvisionFailure() }
        let path = base.appending(path: agentID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        // `WorktreeInfo` has no public memberwise initializer; build it from its JSON.
        let json: [String: String] = ["agentId": agentID, "path": path.path,
                                      "branch": "alethe/agent-\(agentID)", "mode": mode.rawValue]
        return try JSONDecoder().decode(WorktreeInfo.self, from: JSONEncoder().encode(json))
    }, now: { Date(timeIntervalSince1970: 1_000) })
}

private func next(_ iterator: inout AsyncStream<BusEvent>.AsyncIterator) async -> BusEvent? {
    await iterator.next()
}

@Suite struct SchedulerGoldenTests {
    // Upstream `derive_item_task_id_is_deterministic_and_namespaced_by_project`.
    @Test func derivedTaskIDsAreDeterministicAndNamespacedByProject() {
        let a1 = Scheduler.taskID(projectID: "proj-a", text: "Fazer login")
        let a2 = Scheduler.taskID(projectID: "proj-a", text: "Fazer login")
        let b = Scheduler.taskID(projectID: "proj-b", text: "Fazer login")
        #expect(a1 == a2)
        #expect(a1 != b)
        #expect(a1.hasPrefix("proj-a-gsd-"))
    }

    // Upstream `load_gsd_tasks_reads_real_task_md_and_builds_sequential_chain`.
    @Test func loadReadsTaskListAndBuildsASequentialChain() async throws {
        let projectID = uniqueProjectID("chain")
        let root = try await temporaryGitRepo("chain")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTaskList("- [x] Item A\n- [ ] Item B\n- [ ] Item C\n", in: root)

        let scheduler = Scheduler()
        try await scheduler.load(projectID: projectID, repo: root)

        let tasks = await scheduler.tasks(projectID: projectID)
        #expect(tasks.count == 3)
        let a = try #require(tasks.first { $0.title == "Item A" })
        let b = try #require(tasks.first { $0.title == "Item B" })
        let c = try #require(tasks.first { $0.title == "Item C" })
        #expect(a.status == .completed)
        #expect(a.dependencies.isEmpty)
        #expect(b.status == .pending)
        #expect(b.dependencies == [a.id])
        #expect(c.status == .pending)
        #expect(c.dependencies == [b.id])
    }

    // Upstream `load_gsd_tasks_reload_preserves_running_and_drops_stale_pending`.
    @Test func reloadKeepsRunningTasksAndDropsStalePendingOnes() async throws {
        let projectID = uniqueProjectID("reload")
        let root = try await temporaryGitRepo("reload")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTaskList("- [ ] Item A\n- [ ] Item B\n", in: root)
        let scheduler = Scheduler()
        try await scheduler.load(projectID: projectID, repo: root)

        let itemA = Scheduler.taskID(projectID: projectID, text: "Item A")
        let itemB = Scheduler.taskID(projectID: projectID, text: "Item B")
        var running = try #require(await scheduler.tasks[itemA])
        running.status = .running
        running.worktreePath = "/fake/worktree"
        await scheduler.insert(running)

        try writeTaskList("- [ ] Item C\n", in: root)
        try await scheduler.load(projectID: projectID, repo: root)

        let tasks = await scheduler.tasks
        let a = try #require(tasks[itemA], "a running task survives its removed line")
        #expect(a.status == .running)
        #expect(a.worktreePath == "/fake/worktree")
        #expect(tasks[itemB] == nil, "a pending task whose line is gone is dropped")
        #expect(tasks[Scheduler.taskID(projectID: projectID, text: "Item C")] != nil)
    }

    // Upstream `run_scheduler_tick_completes_running_task_when_worktree_planning_is_done`.
    @Test func tickCompletesARunningTaskWhenItsWorktreePlanningIsDone() async throws {
        let projectID = uniqueProjectID("complete")
        let worktree = try temporaryFolder("wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        let planning = worktree.appending(path: ".planning", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: planning, withIntermediateDirectories: true)
        try "Status: Completed\n".write(to: planning.appending(path: "status.md"), atomically: true, encoding: .utf8)

        let taskID = "\(projectID)-manual-task"
        let scheduler = Scheduler()
        await scheduler.insert(SchedulerTask(
            id: taskID, projectID: projectID, title: "Task manual", status: .running,
            assignedAgentID: "agent-manual", leaseResource: "worktree:\(taskID)", worktreePath: worktree.path
        ))

        try await scheduler.tick(projectID: projectID, repo: URL(fileURLWithPath: "/unused-repo-path"))

        #expect(await scheduler.tasks[taskID]?.status == .completed)
        #expect(await !scheduler.leases.contains("worktree:\(taskID)"), "the lease is freed on completion")
    }
}

@Suite struct SchedulerTests {
    @Test func aTickStartsTheFirstReadyTaskOnALeasedWorktreeAndPublishesEachStep() async throws {
        let projectID = uniqueProjectID("start")
        let root = try await temporaryGitRepo("start")
        let base = try temporaryFolder("start-wt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: base)
        }
        try writeTaskList("- [ ] First\n- [ ] Second\n", in: root)
        let bus = EventBus()
        var events = await bus.subscribe().makeAsyncIterator()
        let scheduler = stubScheduler(bus: bus, base: base)

        try await scheduler.trigger(projectID: projectID, repo: root, mode: .localCopy)

        let first = Scheduler.taskID(projectID: projectID, text: "First")
        let second = Scheduler.taskID(projectID: projectID, text: "Second")
        let task = try #require(await scheduler.tasks[first])
        #expect(task.status == .running)
        #expect(task.assignedAgentID == "agent-\(first)")
        #expect(task.leaseResource == "worktree:\(first)")
        #expect(task.worktreePath == base.appending(path: "agent-\(first)").path)
        #expect(await scheduler.tasks[second]?.status == .pending)
        #expect(await scheduler.worktreeMode(for: projectID) == .localCopy)

        let reserved = try #require(await next(&events))
        #expect(reserved.type == SchedulerEvent.taskReserved)
        #expect(reserved.taskID == projectID)
        #expect(reserved.agentID == first)
        #expect(reserved.correlationID.hasPrefix("sched-"))
        #expect(reserved.timestampMS == 1_000_000)
        let started = try #require(await next(&events))
        #expect(started.type == SchedulerEvent.taskStarted)
        #expect(started.data == .object(["agent_id": .string("agent-\(first)")]))
        let spawn = try #require(await next(&events))
        #expect(spawn.type == SchedulerEvent.agentSpawnRequested)
        #expect(spawn.data == .object([
            "agent_id": .string("agent-\(first)"),
            "worktree_path": .string(task.worktreePath ?? ""),
            "task_title": .string("First"),
        ]))
    }

    @Test func aFailedProvisionFailsTheTaskAndFreesItsLease() async throws {
        let projectID = uniqueProjectID("fail")
        let root = try await temporaryGitRepo("fail")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTaskList("- [ ] Only\n", in: root)
        let scheduler = stubScheduler(base: root, failing: true)

        try await scheduler.trigger(projectID: projectID, repo: root)

        let id = Scheduler.taskID(projectID: projectID, text: "Only")
        let task = try #require(await scheduler.tasks[id])
        #expect(task.status == .failed)
        #expect(task.assignedAgentID == nil)
        #expect(task.leaseResource == nil)
        #expect(await scheduler.leases.isEmpty)
    }

    @Test func cancelFailsARunningTaskFreesItsLeaseAndLeavesOthersAlone() async throws {
        let bus = EventBus()
        var events = await bus.subscribe().makeAsyncIterator()
        let scheduler = Scheduler(bus: bus)
        await scheduler.insert(SchedulerTask(id: "p-run", projectID: "p", title: "run", status: .running,
                                             assignedAgentID: "agent-p-run", leaseResource: "worktree:p-run"))
        await scheduler.insert(SchedulerTask(id: "p-wait", projectID: "p", title: "wait"))

        #expect(await scheduler.cancel(taskID: "p-run"))
        #expect(await !scheduler.cancel(taskID: "p-wait"))
        #expect(await !scheduler.cancel(taskID: "missing"))

        let cancelled = try #require(await scheduler.tasks["p-run"])
        #expect(cancelled.status == .failed)
        #expect(cancelled.assignedAgentID == nil)
        #expect(await scheduler.leases.isEmpty)
        #expect(await scheduler.tasks["p-wait"]?.status == .pending)

        let event = try #require(await next(&events))
        #expect(event.type == SchedulerEvent.taskFailed)
        #expect(event.correlationID.hasPrefix("cancel-"))
        #expect(event.data == .object(["reason": .string("Cancelled by user")]))
    }

    @Test func aTaskWaitsUntilItsDependencyIsCompleted() async throws {
        let scheduler = Scheduler(provision: { _, _, _ in throw ProvisionFailure() })
        await scheduler.insert(SchedulerTask(id: "p-a", projectID: "p", title: "a", status: .running,
                                             leaseResource: "worktree:p-a"))
        await scheduler.insert(SchedulerTask(id: "p-b", projectID: "p", title: "b", dependencies: ["p-a"]))
        await scheduler.insert(SchedulerTask(id: "p-c", projectID: "p", title: "c", dependencies: ["p-missing"]))

        try await scheduler.tick(projectID: "p", repo: URL(fileURLWithPath: "/unused"))

        #expect(await scheduler.tasks["p-b"]?.status == .pending)
        #expect(await scheduler.tasks["p-c"]?.status == .pending, "an unknown dependency never counts as done")
    }

    @Test func loadOutsideARepositoryFails() async throws {
        let folder = try temporaryFolder("norepo")
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: SchedulerError.notARepository) {
            try await Scheduler().load(projectID: "p", repo: folder)
        }
    }

    @Test func autoTickIsOffUntilStartedAndTicksOnPlanningUpdated() async throws {
        let projectID = uniqueProjectID("auto")
        let root = try await temporaryGitRepo("auto")
        let base = try temporaryFolder("auto-wt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: base)
        }
        try writeTaskList("- [ ] Only\n", in: root)
        let bus = EventBus()
        let scheduler = stubScheduler(bus: bus, base: base)
        #expect(await !scheduler.isAutoTicking)

        var events = await bus.subscribe().makeAsyncIterator()
        await scheduler.startAutoTick(on: bus)
        let planningDir = root.appending(path: ".planning").path
        await bus.publish(BusEventType.planningUpdated, correlationID: "gsd-1", taskID: projectID,
                          data: .object(["action": .string("Modify"), "planning_dir": .string(planningDir)]))

        var seen: [String] = []
        while let event = await next(&events), seen.count < 4 {
            seen.append(event.type)
            if event.type == SchedulerEvent.agentSpawnRequested { break }
        }
        #expect(seen == [BusEventType.planningUpdated, SchedulerEvent.taskReserved,
                         SchedulerEvent.taskStarted, SchedulerEvent.agentSpawnRequested])
        await scheduler.stopAutoTick()
        #expect(await !scheduler.isAutoTicking)
    }

    @Test func tasksEncodeInUpstreamCamelCaseWithNulls() throws {
        let task = SchedulerTask(id: "p-1", projectID: "p", title: "t", status: .ready)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(task), as: UTF8.self)
        #expect(json == #"{"assignedAgentId":null,"dependencies":[],"id":"p-1","leaseResource":null,"priority":0,"projectId":"p","status":"ready","title":"t","worktreePath":null}"#)
        #expect(try JSONDecoder().decode(SchedulerTask.self, from: Data(json.utf8)) == task)
    }
}
