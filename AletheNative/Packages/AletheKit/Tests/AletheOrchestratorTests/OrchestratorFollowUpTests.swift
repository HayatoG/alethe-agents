import Foundation
import Testing
import AletheGit
import AletheIntegrations
@testable import AletheOrchestrator

// Upstream `tests/orchestrator.rs` cases for steering, follow-ups, approvals and isolation (P6-7),
// plus units. Workers are fake launchers (shell scripts); git runs on temporary repositories with
// the user's and the system's git configuration shut out.

private let gitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

private func temporaryDirectory(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "alethe-orch-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A worker that starts and never speaks the protocol (upstream `silent_launcher`).
private func silentLauncher() -> Launcher {
    Launcher(kind: WorkerAgent.codex, program: URL(filePath: "/bin/sleep"), arguments: ["60"])
}

/// A fake `codex app-server` that opens (or resumes) a thread and reports each turn as
/// "did <text>" after `turnSeconds`, so the order of turns shows in the deliveries.
private func echoCodexLauncher(in folder: URL, turnSeconds: Int = 0) throws -> Launcher {
    let script = folder.appending(path: "echo-codex.sh")
    try """
    n=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"thread/start"'*|*'"method":"thread/resume"'*)
          printf '{"id":2,"result":{"thread":{"id":"thread-echo"}}}\\n' ;;
        *'"method":"turn/start"'*)
          n=$((n+1))
          text=$(printf '%s' "$line" | sed -n 's/.*"text":"\\([^"]*\\)".*/\\1/p')
          printf '{"method":"turn/started","params":{"turn":{"id":"turn-%s"}}}\\n' "$n"
          sleep \(turnSeconds)
          printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"did %s"}}}\\n' "$text"
          printf '{"method":"turn/completed","params":{}}\\n' ;;
      esac
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    return Launcher(kind: WorkerAgent.codex, program: URL(filePath: "/bin/sh"), arguments: [script.path])
}

/// A fake `codex app-server` that stops on a command approval (rpc id 77) in its first turn and
/// reports the decision it was given, and whether its thread was opened with the granular policy.
private func askingCodexLauncher(in folder: URL) throws -> Launcher {
    let script = folder.appending(path: "asking-codex.sh")
    try """
    policy=never
    while IFS= read -r line; do
      case "$line" in
        *'"method":"thread/start"'*)
          case "$line" in *'"granular"'*) policy=granular ;; esac
          printf '{"id":2,"result":{"thread":{"id":"thread-ask"}}}\\n' ;;
        *'"method":"turn/start"'*)
          printf '{"method":"turn/started","params":{"turn":{"id":"turn-1"}}}\\n'
          printf '{"id":77,"method":"item/commandExecution/requestApproval","params":{"command":"touch x","cwd":"/tmp","reason":"needs a file"}}\\n' ;;
        *'"id":77'*)
          decision=$(printf '%s' "$line" | sed -n 's/.*"decision":"\\([^"]*\\)".*/\\1/p')
          printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"%s %s"}}}\\n' "$decision" "$policy"
          printf '{"method":"turn/completed","params":{}}\\n' ;;
      esac
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    return Launcher(kind: WorkerAgent.codex, program: URL(filePath: "/bin/sh"), arguments: [script.path])
}

/// A fake Claude headless worker: every user line is one turn that ends in a `result`.
private func fakeClaudeLauncher() -> Launcher {
    let script = #"""
    while IFS= read -r line; do
      printf '{"type":"system","subtype":"init","session_id":"session-%s"}\n' "$$"
      printf '{"type":"result","is_error":false,"result":"ok"}\n'
    done
    """#
    return Launcher(kind: WorkerAgent.claude, program: URL(filePath: "/bin/sh"), arguments: ["-c", script])
}

private func makeCore(_ launchers: [Launcher] = []) -> OrchestratorCore {
    var configured = WorkerLaunchers()
    for launcher in launchers { configured.set(launcher) }
    return OrchestratorCore(configuration: .init(
        launchers: configured,
        uncommittedDiff: { _ in nil },
        terminationGrace: .milliseconds(500),
        worktrees: GitWorktrees(runner: GitRunner(environment: gitEnvironment))
    ))
}

/// One `tools/call` through the MCP transport (upstream `call`): the tool's JSON, or `{"error": …}`.
private func call(_ core: OrchestratorCore, _ name: String, _ arguments: OrderedJSON) async throws -> OrderedJSONObject {
    let body: OrderedJSON = [
        "jsonrpc": "2.0", "id": 10, "method": "tools/call",
        "params": ["name": .string(name), "arguments": arguments],
    ]
    let raw = try #require(await OrchestratorMCP.handle(body: body.compactRendered(), planner: nil, handler: core))
    let result = try #require(try OrderedJSON.parse(raw).objectValue?["result"]?.objectValue)
    let text = try #require(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    if result["isError"] == true { return ["error": .string(text)] }
    return (try? OrderedJSON.parse(text).objectValue) ?? ["raw": .string(text)]
}

private func deliveryTexts(_ checked: OrderedJSONObject) -> [String] {
    checked["deliveries"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue } ?? []
}

/// The refusal a core call ends in, or nil when it succeeded.
private func refusal(_ operation: () async throws -> OrderedJSON) async -> String? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return (error as? OrchestratorToolError)?.message ?? "\(error)"
    }
}

/// Polls the core until `condition` holds for job-01, at most 10 s.
private func waitForJob(_ core: OrchestratorCore, _ jobID: String = "job-01",
                        _ condition: (Job) -> Bool) async throws -> Job {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if let job = await core.job(jobID), condition(job) { return job }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("job \(jobID) never reached the expected state")
    return try #require(await core.job(jobID))
}

@discardableResult
private func git(_ arguments: [String], in folder: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = folder
    process.environment = ProcessInfo.processInfo.environment.merging(gitEnvironment) { _, new in new }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GitError.commandFailed(exitCode: process.terminationStatus, stderr: "") }
    return String(decoding: data, as: UTF8.self)
}

/// A repository with one commit holding `seed.txt`.
private func seededRepository(_ tag: String) throws -> URL {
    let folder = try temporaryDirectory(tag)
    try git(["init", "-q"], in: folder)
    try git(["config", "user.email", "lab@example.com"], in: folder)
    try git(["config", "user.name", "lab"], in: folder)
    try "seed".write(to: folder.appending(path: "seed.txt"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: folder)
    try git(["commit", "-qm", "seed"], in: folder)
    return folder
}

private func removeRepository(_ folder: URL) {
    if let listed = try? git(["worktree", "list", "--porcelain"], in: folder) {
        for entry in GitWorktrees.parsePorcelain(listed).dropFirst() {
            _ = try? git(["worktree", "remove", "--force", entry.path], in: folder)
        }
    }
    try? FileManager.default.removeItem(at: folder)
}

@Suite(.timeLimit(.minutes(1))) struct OrchestratorFollowUpTests {
    // Upstream `answering_is_refused_when_nothing_is_waiting`.
    @Test func answeringIsRefusedWhenNothingIsWaiting() async throws {
        let folder = try temporaryDirectory("answer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([silentLauncher()])
        _ = try await call(core, "alethe_delegate", ["tasks": ["work"], "cwd": .string(folder.path)])
        try await Task.sleep(for: .milliseconds(300))

        let refused = await refusal { try await core.answer(job: "job-01", decision: "accept") }
        #expect(refused?.contains("not waiting") == true, "got: \(refused ?? "success")")
        let unknown = await refusal { try await core.answer(job: "job-99", decision: "accept") }
        #expect(unknown?.contains("unknown job") == true, "got: \(unknown ?? "success")")
        let bad = await refusal { try await core.answer(job: "job-01", decision: "maybe") }
        #expect(bad?.contains("decision must be") == true, "got: \(bad ?? "success")")
        await core.shutdown()
    }

    // Upstream `steering_an_unknown_job_is_refused`.
    @Test func steeringAnUnknownJobIsRefused() async throws {
        let core = makeCore()
        let result = try await call(core, "alethe_steer", ["jobId": "job-99", "message": "turn left"])
        #expect(result["error"]?.stringValue?.contains("unknown job") == true, "\(result)")
    }

    // Upstream `isolating_outside_a_repository_says_so`.
    @Test func isolatingOutsideARepositorySaysSo() async throws {
        let folder = try temporaryDirectory("norepo")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([silentLauncher()])
        let result = try await call(core, "alethe_delegate", [
            "cwd": .string(folder.path), "tasks": ["anything"], "isolate": true,
        ])
        #expect(result["error"]?.stringValue?.contains("git repository") == true, "\(result)")
        #expect(await core.snapshot().jobs.isEmpty, "a refused batch leaves no job behind")
    }

    // Upstream `isolating_gives_each_worker_its_own_worktree`.
    @Test func isolatingGivesEachWorkerItsOwnWorktree() async throws {
        let repo = try seededRepository("isolate")
        defer { removeRepository(repo) }
        let core = makeCore([silentLauncher()])
        let delegated = try await call(core, "alethe_delegate", [
            "cwd": .string(repo.path), "tasks": ["one", "two"], "isolate": true, "timeoutSeconds": 2,
        ])
        #expect(delegated["accepted"] == 2, "\(delegated)")
        #expect(delegated["isolated"] == true, "\(delegated)")

        let listed = try #require(delegated["jobs"]?.arrayValue)
        var paths: [String] = []
        for (index, job) in listed.enumerated() {
            let path = try #require(job.objectValue?["worktree"]?.stringValue, "a worktree path")
            #expect(FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: "seed.txt").path),
                    "worktree was not checked out at \(path)")
            #expect(path.hasSuffix(".alethe/worktrees/job-0\(index + 1)"), "\(path)")
            paths.append(path)
        }
        #expect(paths.count == 2 && paths[0] != paths[1], "both workers landed in the same directory")
        // Each job works inside its worktree, on upstream's branch.
        #expect(await core.job("job-01")?.cwd == paths.first)
        #expect(await core.job("job-01")?.worktree == paths.first)
        try git(["rev-parse", "--verify", "refs/heads/alethe/agent-job-01"], in: repo)
        try git(["rev-parse", "--verify", "refs/heads/alethe/agent-job-02"], in: repo)

        _ = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 30000])
        await core.shutdown()
    }

    @Test func aHalfMadeBatchIsRolledBack() async throws {
        let repo = try seededRepository("rollback")
        defer { removeRepository(repo) }
        // The second job's worktree folder is taken, so the batch fails after the first was made.
        try FileManager.default.createDirectory(
            at: repo.appending(path: ".alethe/worktrees/job-02"), withIntermediateDirectories: true)
        let core = makeCore([silentLauncher()])
        let result = try await call(core, "alethe_delegate", [
            "cwd": .string(repo.path), "tasks": ["one", "two"], "isolate": true,
        ])
        let error = try #require(result["error"]?.stringValue, "\(result)")
        #expect(error.contains("git repository") && error.contains("already exists"), "\(error)")

        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: ".alethe/worktrees/job-01").path))
        #expect(try git(["branch", "--list", "alethe/agent-job-01"], in: repo).isEmpty, "the branch was left behind")
        #expect(GitWorktrees.parsePorcelain(try git(["worktree", "list", "--porcelain"], in: repo)).count == 1)
        #expect(await core.snapshot().jobs.isEmpty, "nothing of the batch was accepted")
        #expect(await core.counts().queued == 0)

        // The refused batch's ids stay spent, as upstream reserves them before the worktrees.
        let next = try await call(core, "alethe_delegate", ["cwd": .string(repo.path), "tasks": ["three"]])
        #expect(next["jobs"]?.arrayValue?.first?.objectValue?["id"] == "job-03", "\(next)")
        await core.shutdown()
    }

    @Test func delegateOptionsReachTheJob() async throws {
        let request = try DelegateRequest(arguments: [
            "tasks": ["x"], "cwd": "/tmp", "askForApproval": true, "webSearch": true, "isolate": true,
        ])
        #expect(request.askForApproval && request.webSearch && request.isolate)
        let plain = try DelegateRequest(arguments: ["tasks": ["x"], "cwd": "/tmp"])
        #expect(!plain.askForApproval && !plain.webSearch && !plain.isolate)

        let folder = try temporaryDirectory("options")
        defer { try? FileManager.default.removeItem(at: folder) }
        // No launcher: the job fails cleanly but keeps what it was asked to run with.
        let core = makeCore()
        let delegated = try await call(core, "alethe_delegate", [
            "tasks": ["x"], "cwd": .string(folder.path), "askForApproval": true, "webSearch": true,
        ])
        #expect(delegated["isolated"] == false, "\(delegated)")
        let job = try #require(await core.job("job-01"))
        #expect(job.approvalPolicy.contains("granular"))
        #expect(job.sandbox == Job.defaultSandbox, "asking keeps the sandbox writable")
        #expect(job.webSearch)
        await core.shutdown()
    }

    @Test func aBlockedWorkerIsAnsweredAndCarriesOn() async throws {
        let folder = try temporaryDirectory("approve")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([try askingCodexLauncher(in: folder)])
        _ = try await call(core, "alethe_delegate", [
            "tasks": ["make a file"], "cwd": .string(folder.path), "askForApproval": true,
        ])
        let blocked = try await waitForJob(core) { $0.status == .blocked }
        #expect(blocked.pending?.objectValue?["kind"] == "command")
        #expect(blocked.pending?.objectValue?["command"] == "touch x")

        let answered = try await call(core, "alethe_answer", ["jobId": "job-01", "decision": "acceptForSession"])
        #expect(answered["answered"] == "job-01", "\(answered)")
        #expect(answered["decision"] == "acceptForSession")
        #expect(await core.job("job-01")?.pending == nil, "the ask clears once answered")

        let checked = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])
        #expect(deliveryTexts(checked) == ["acceptForSession granular"], "\(checked)")
        let again = await refusal { try await core.answer(job: "job-01", decision: .accept) }
        #expect(again?.contains("not waiting") == true, "got: \(again ?? "success")")
        await core.shutdown()
    }

    @Test func messagesToABusyWorkerRunInOrderAsItsNextTurns() async throws {
        let folder = try temporaryDirectory("inbox")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([try echoCodexLauncher(in: folder, turnSeconds: 1)])
        _ = try await call(core, "alethe_delegate", ["tasks": ["start"], "cwd": .string(folder.path)])
        _ = try await waitForJob(core) { $0.status == .running && $0.activeTurnID != nil }

        let first = try await call(core, "alethe_send", ["jobId": "job-01", "message": "first"])
        #expect(first["queued"] == "job-01" && first["waiting"] == 1, "\(first)")
        let second = try await call(core, "alethe_send", ["jobId": "job-01", "message": "second"])
        #expect(second["waiting"] == 2, "\(second)")
        #expect(await core.job("job-01")?.inbox == ["first", "second"])

        let checked = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 20000])
        #expect(deliveryTexts(checked) == ["did start", "did first", "did second"], "\(checked)")
        #expect(await core.job("job-01")?.inbox.isEmpty == true)
        await core.shutdown()
    }

    @Test func aParkedWorkerTakesAMessageAtOnceAndAReleasedOneIsRevived() async throws {
        let folder = try temporaryDirectory("revive")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([try echoCodexLauncher(in: folder)])
        _ = try await call(core, "alethe_delegate", ["tasks": ["start"], "cwd": .string(folder.path)])
        _ = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])

        // Parked: the process is still there, the message is its next turn right away.
        let sent = try await call(core, "alethe_send", ["jobId": "job-01", "message": "again"])
        #expect(sent["sent"] == "job-01", "\(sent)")
        var checked = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])
        #expect(deliveryTexts(checked) == ["did again"], "\(checked)")

        // Released: the process is gone, the worker is started again on its thread.
        #expect(await core.release(["job-01"]) == ["job-01"])
        let revived = try await call(core, "alethe_send", ["jobId": "job-01", "message": "later"])
        #expect(revived["revived"] == "job-01", "\(revived)")
        #expect(revived["resumedThread"] == "thread-echo")
        checked = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])
        #expect(deliveryTexts(checked) == ["did later"], "\(checked)")
        #expect(await core.job("job-01")?.threadID == "thread-echo")
        await core.shutdown()
    }

    @Test func sendingToAJobWithoutAThreadIsRefused() async throws {
        let folder = try temporaryDirectory("nothread")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([silentLauncher()])
        _ = try await call(core, "alethe_delegate", ["tasks": ["x"], "cwd": .string(folder.path)])
        let result = try await call(core, "alethe_send", ["jobId": "job-01", "message": "hello"])
        #expect(result["error"]?.stringValue?.contains("has no thread") == true, "\(result)")
        let missing = try await call(core, "alethe_send", ["jobId": "job-01"])
        #expect(missing["error"] == "error: message is required", "\(missing)")
        await core.shutdown()
    }

    @Test func steeringACodexWorkerGoesIntoItsRunningTurn() async throws {
        let folder = try temporaryDirectory("steer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([try echoCodexLauncher(in: folder, turnSeconds: 2)])
        _ = try await call(core, "alethe_delegate", ["tasks": ["start"], "cwd": .string(folder.path)])
        _ = try await waitForJob(core) { $0.activeTurnID != nil }

        let steered = try await call(core, "alethe_steer", ["jobId": "job-01", "message": "left"])
        #expect(steered["steered"] == "job-01", "\(steered)")
        #expect(steered["turnId"] == "turn-1")

        _ = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])
        let idle = try await call(core, "alethe_steer", ["jobId": "job-01", "message": "right"])
        #expect(idle["error"]?.stringValue?.contains("no running turn") == true, "\(idle)")
        await core.shutdown()
    }

    @Test func steeringAnIdleClaudeWorkerQueuesItsNextTurn() async throws {
        let folder = try temporaryDirectory("claude-steer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([fakeClaudeLauncher()])
        _ = try await call(core, "alethe_delegate", ["tasks": ["start"], "agent": "claude", "cwd": .string(folder.path)])
        _ = try await call(core, "alethe_check", ["wait": true, "timeoutMs": 10000])

        let steered = try await call(core, "alethe_steer", ["jobId": "job-01", "message": "and then"])
        #expect(steered["queued"] == "job-01", "\(steered)")
        #expect(steered["waiting"] == 1)
        #expect(steered["note"] != nil)
        #expect(await core.job("job-01")?.inbox == ["and then"])
        await core.shutdown()
    }

    @Test func theDiffIsEmptyUntilTheWorkerHasOne() async throws {
        let folder = try temporaryDirectory("diff")
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = makeCore([silentLauncher()])
        _ = try await call(core, "alethe_delegate", ["tasks": ["x"], "cwd": .string(folder.path)])
        let diff = try await call(core, "alethe_diff", ["jobId": "job-01"])
        #expect(diff["jobId"] == "job-01" && diff["diff"] == "", "\(diff)")
        #expect(try await core.jobDiff("job-01") == "")
        let unknown = await refusal { .string(try await core.jobDiff("job-99")) }
        #expect(unknown?.contains("unknown job") == true, "got: \(unknown ?? "success")")
        await core.shutdown()
    }
}
