import AletheGit
import Foundation
import Testing
@testable import AletheMerge

/// P6-16: applying a worker's worktree — step order and stop points over stub operations (U), and
/// the real pipeline on throwaway repositories (G).
struct WorktreeApplyTests {
    // MARK: U — stubs

    /// Records every operation in call order; `analysisClean`/`finalizeOutcome` steer the path.
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var branch: String? = "main"
        var analysisClean = true
        var finalizeOutcome = MergeFinishOutcome(merged: true, stage: .merged, output: "merge(alethe)")
        var failFetch = false

        var calls: [String] { lock.withLock { log } }
        func record(_ name: String) { lock.withLock { log.append(name) } }

        var operations: WorktreeApplyOperations {
            WorktreeApplyOperations(
                mainRoot: { _ in URL(fileURLWithPath: "/repo") },
                currentBranch: { _ in self.branch },
                pendingChanges: { _, _ in ["new.txt"] },
                committedFiles: { _, _, _ in ["old.txt", "new.txt"] },
                commitPending: { _, id, message in
                    self.record("commit:\(id):\(message)")
                    return true
                },
                fetchBranch: { _, _ in
                    self.record("fetch")
                    if self.failFetch { throw GitWorktreeError.notFound }
                },
                analyze: { _, source, target in
                    self.record("analyze:\(source)->\(target)")
                    return MergeAnalysis(clean: self.analysisClean, source: source, target: target,
                                         conflicts: self.analysisClean ? [] : [ConflictFile(path: "a.ts")])
                },
                prepare: { _, _, _, project in
                    self.record("prepare:\(project ?? "-")")
                    return ConflictEnvironment(id: "env1", path: URL(fileURLWithPath: "/repo/.alethe/merge-envs/env1"),
                                               branch: "alethe/merge-env1", clean: self.analysisClean,
                                               conflicts: self.analysisClean ? [] : [ConflictFile(path: "a.ts")],
                                               promptPath: nil)
                },
                finalize: { _, handle in
                    self.record("finalize:\(handle.id)")
                    return self.finalizeOutcome
                },
                abort: { _, handle in self.record("abort:\(handle.id)") }
            )
        }
    }

    func preview(_ stub: Stub) async throws -> WorktreeApplyPreview {
        try await WorktreeApply(operations: stub.operations)
            .preview(worktree: URL(fileURLWithPath: "/repo/.alethe/worktrees/job-1"), agentID: "job-1")
    }

    @Test func previewNamesTargetSourceAndFiles() async throws {
        let stub = Stub()
        let preview = try await preview(stub)
        #expect(preview.source == "alethe/agent-job-1")
        #expect(preview.target == "main")
        #expect(preview.pending == ["new.txt"])
        #expect(preview.files == ["new.txt", "old.txt"])
        #expect(stub.calls.isEmpty, "a preview writes nothing")
    }

    @Test func previewRefusesDetachedOrSameBranch() async throws {
        let stub = Stub()
        stub.branch = nil
        await #expect(throws: WorktreeApplyError.detachedTarget) { try await preview(stub) }
        stub.branch = "alethe/agent-job-1"
        await #expect(throws: WorktreeApplyError.sameBranch("alethe/agent-job-1")) { try await preview(stub) }
        await #expect(throws: GitWorktreeError.invalidAgentId) {
            try await WorktreeApply(operations: stub.operations).preview(worktree: URL(fileURLWithPath: "/x"), agentID: "../x")
        }
    }

    @Test func cleanApplyRunsEveryStepInOrder() async throws {
        let stub = Stub()
        let steps = StepLog()
        let result = try await WorktreeApply(operations: stub.operations)
            .run(try await preview(stub), projectID: "p1") { steps.append($0) }
        #expect(result.outcome == .applied)
        #expect(result.committedPending)
        #expect(steps.all == WorktreeApplyStep.allCases)
        #expect(stub.calls == ["commit:job-1:Alethe orchestrator: job-1", "fetch",
                               "analyze:alethe/agent-job-1->main", "prepare:p1", "finalize:env1"])
    }

    @Test func aFailedFetchIsIgnored() async throws {
        let stub = Stub()
        stub.failFetch = true
        let result = try await WorktreeApply(operations: stub.operations).run(try await preview(stub))
        #expect(result.outcome == .applied)
    }

    @Test func conflictStopsBeforeFinalizeWithAnEnvironment() async throws {
        let stub = Stub()
        stub.analysisClean = false
        let result = try await WorktreeApply(operations: stub.operations).run(try await preview(stub))
        #expect(result.outcome == .conflicted(environmentID: "env1"))
        #expect(result.analysis?.clean == false)
        #expect(!stub.calls.contains { $0.hasPrefix("finalize") || $0.hasPrefix("abort") })
    }

    @Test func aStoppedFinalizeKeepsTheEnvironment() async throws {
        let stub = Stub()
        stub.finalizeOutcome = MergeFinishOutcome(merged: false, stage: .targetNotCheckedOut, output: "moved")
        let result = try await WorktreeApply(operations: stub.operations).run(try await preview(stub))
        #expect(result.outcome == .notMerged(environmentID: "env1", stage: .targetNotCheckedOut, output: "moved"))
        #expect(!stub.calls.contains { $0.hasPrefix("abort") })
    }

    @Test func nothingToIntegrateDiscardsTheEnvironment() async throws {
        let stub = Stub()
        stub.finalizeOutcome = MergeFinishOutcome(merged: false, stage: .nothingToIntegrate, output: "")
        let result = try await WorktreeApply(operations: stub.operations).run(try await preview(stub))
        #expect(result.outcome == .nothingToApply)
        #expect(result.environment == nil)
        #expect(stub.calls.last == "abort:env1")
    }

    /// Cancelling while a step runs lets that step finish and stops before the next one; once the
    /// merge step starts the apply completes.
    @Test(arguments: WorktreeApplyStep.allCases)
    func cancelStopsAtTheNextBoundary(_ step: WorktreeApplyStep) async throws {
        let stub = Stub()
        let preview = try await preview(stub)
        let result = try await WorktreeApply(operations: stub.operations).run(preview) { current in
            if current == step { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let expected: [String] = switch step {
        case .committing: ["commit"]
        case .fetching: ["commit", "fetch"]
        case .analyzing: ["commit", "fetch", "analyze"]
        case .preparing: ["commit", "fetch", "analyze", "prepare", "abort"]
        case .finalizing: ["commit", "fetch", "analyze", "prepare", "finalize"]
        }
        #expect(stub.calls.map { String($0.prefix { $0 != ":" }) } == expected)
        #expect(result.outcome == (step == .finalizing ? .applied : .cancelled))
        #expect(step.isCancelable == (step != .finalizing))
    }

    @Test func cancelledBeforeStartingDoesNothing() async throws {
        let stub = Stub()
        let preview = try await preview(stub)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorktreeApply(operations: stub.operations).run(preview)
        }
        #expect(try await task.value.outcome == .cancelled)
        #expect(stub.calls.isEmpty)
    }

    final class StepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [WorktreeApplyStep] = []
        func append(_ step: WorktreeApplyStep) { lock.withLock { steps.append(step) } }
        var all: [WorktreeApplyStep] { lock.withLock { steps } }
    }

    // MARK: G — throwaway repositories

    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    static func git(_ dir: URL, _ args: String...) async throws -> String {
        try await runner.run(args, in: dir).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `main` with `a.txt`, and job `job-1`'s worktree on `alethe/agent-job-1`.
    static func repoWithWorktree() async throws -> (root: URL, worktree: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-apply-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await git(root, "init", "-b", "main")
        _ = try await git(root, "config", "user.name", "Alethe Test")
        _ = try await git(root, "config", "user.email", "test@alethe.local")
        _ = try await git(root, "config", "commit.gpgsign", "false")
        try "base\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, "add", "-A")
        _ = try await git(root, "commit", "-m", "base")
        let info = try await GitWorktrees(runner: runner).provision(repo: root, agentId: "job-1", mode: .gitWorktree)
        return (root, URL(fileURLWithPath: info.path, isDirectory: true))
    }

    @Test func appliesPendingWorkIntoTheCheckedOutBranch() async throws {
        let (root, worktree) = try await Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        try "from the worker\n".write(to: worktree.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let apply = WorktreeApply(operations: .live(runner: Self.runner))
        let preview = try await apply.preview(worktree: worktree, agentID: "job-1")
        #expect(preview.root.standardizedFileURL == root.standardizedFileURL)
        #expect(preview.target == "main")
        #expect(preview.files == ["new.txt"])

        let result = try await apply.run(preview, projectID: "p1")
        #expect(result.outcome == .applied)
        #expect(result.committedPending)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path),
                "the checked-out target moved forward")
        #expect(try await Self.git(worktree, "status", "--porcelain").isEmpty)
        #expect(try await Self.git(root, "log", "-1", "--format=%s") == "merge(alethe): alethe/agent-job-1 -> main")
        let envs = MergeAnalyzer.mergeEnvsDirectory(root: root)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: envs.path)) ?? []).filter { !$0.hasSuffix(".json") }
        #expect(left.isEmpty, "the merge environment is torn down")
    }

    @Test func aConflictLeavesAnEnvironmentForTheMergeCenter() async throws {
        let (root, worktree) = try await Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        try "main side\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Self.git(root, "commit", "-am", "main moves")
        try "worker side\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let before = try await Self.git(root, "rev-parse", "HEAD")

        let apply = WorktreeApply(operations: .live(runner: Self.runner))
        let result = try await apply.run(try await apply.preview(worktree: worktree, agentID: "job-1"))
        guard case .conflicted(let id) = result.outcome else {
            Issue.record("expected a conflict, got \(result.outcome)")
            return
        }
        #expect(try await Self.git(root, "rev-parse", "HEAD") == before, "the target is untouched")
        let resumed = try await ConflictResolution(root: root, runner: Self.runner).resume(id: id)
        #expect(resumed.meta.source == "alethe/agent-job-1")
        #expect(resumed.meta.target == "main")
        #expect(resumed.environment.conflicts.map(\.path) == ["a.txt"])
    }

    @Test func aWorkerWithoutChangesHasNothingToApply() async throws {
        let (root, worktree) = try await Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let apply = WorktreeApply(operations: .live(runner: Self.runner))
        let result = try await apply.run(try await apply.preview(worktree: worktree, agentID: "job-1"))
        #expect(result.outcome == .nothingToApply)
        #expect(!result.committedPending)
        #expect(ConflictResolution(root: root, runner: Self.runner).inProgress().isEmpty)
    }
}
