import AletheGit
import Foundation
import Testing
@testable import AletheMerge

/// Ports of upstream `conflict_resolution.rs` tests against throwaway repositories.
struct ConflictResolutionTests {
    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    /// `main` plus `agent-a` / `agent-b` that both edit `shared.ts`, and `agent-c` touching another file.
    func repo() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-conflict-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: String...) async throws { _ = try await Self.runner.run(args, in: root) }
        try await git("init", "-b", "main")
        try await git("config", "user.name", "Alethe Test")
        try await git("config", "user.email", "alethe@example.invalid")
        try await git("config", "commit.gpgsign", "false")
        try write(root, "shared.ts", "export const value = 'base'\n")
        try await git("add", ".")
        try await git("commit", "-m", "base")
        for (branch, file, text) in [
            ("agent-a", "shared.ts", "export const value = 'from-a'\n"),
            ("agent-b", "shared.ts", "export const value = 'from-b'\n"),
            ("agent-c", "extra.rs", "fn extra() {}\n"),
        ] {
            try await git("checkout", "-b", branch, "main")
            try write(root, file, text)
            try await git("add", ".")
            try await git("commit", "-m", branch)
        }
        try await git("checkout", "main")
        return root
    }

    func write(_ dir: URL, _ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func git(_ args: [String], in dir: URL) async throws -> String {
        try await Self.runner.run(args, in: dir).text
    }

    @Test func cleanPrepareHasNoPrompt() async throws {
        let root = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ConflictResolution(root: root, runner: Self.runner)
        let steps = StepLog()
        let env = try await resolution.prepare(source: "agent-c", target: "agent-a") { steps.append($0) }
        #expect(env.clean)
        #expect(env.conflicts.isEmpty)
        #expect(env.promptPath == nil)
        #expect(env.branch == "alethe/merge-\(env.id)")
        #expect(steps.values == [.creatingEnvironment, .merging])
        #expect(try resolution.readMeta(id: env.id).conflictPaths.isEmpty)
        try await resolution.abort(id: env.id)
    }

    @Test func conflictingPrepareListsConflictsAndIsAbortable() async throws {
        let root = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ConflictResolution(root: root, runner: Self.runner)
        let env = try await resolution.prepare(source: "agent-b", target: "agent-a", projectId: "p1")
        #expect(!env.clean)
        #expect(env.conflicts == [ConflictFile(path: "shared.ts", class: .typeScript)])
        let prompt = try String(contentsOf: try #require(env.promptPath), encoding: .utf8)
        #expect(prompt.contains("- `shared.ts` — TypeScript: \(ConflictClass.typeScript.strategy)"))
        let marked = try String(contentsOf: env.path.appendingPathComponent("shared.ts"), encoding: .utf8)
        #expect(marked.contains("<<<<<<<"))
        let meta = try resolution.readMeta(id: env.id)
        #expect(meta.projectId == "p1" && meta.conflictPaths == ["shared.ts"])
        #expect(try await resolution.conflicts(id: env.id).map(\.path) == ["shared.ts"])

        // The user's tree is untouched.
        #expect(try await git(["status", "--porcelain", "--untracked-files=no"], in: root).isEmpty)

        // Resumable: the merge stays in progress until preflight abort clears it (then a no-op).
        _ = try await git(["rev-parse", "--verify", "MERGE_HEAD"], in: env.path)
        try await resolution.preflightAbort(id: env.id)
        try await resolution.preflightAbort(id: env.id)
        #expect(try await resolution.conflicts(id: env.id).isEmpty)

        // Abort restores: no worktree, branch or metadata left behind.
        try await resolution.abort(id: env.id)
        #expect(!FileManager.default.fileExists(atPath: env.path.path))
        #expect(!FileManager.default.fileExists(atPath: resolution.metaURL(id: env.id).path))
        #expect(try await git(["branch", "--list", "alethe/*"], in: root).isEmpty)
        await #expect(throws: ConflictResolutionError.invalidEnvironmentID("../evil")) {
            try await resolution.abort(id: "../evil")
        }
        await #expect(throws: ConflictResolutionError.environmentNotFound("missing")) {
            try await resolution.preflightAbort(id: "missing")
        }
    }

    @Test func rebaseOntoTargetReconcilesOrReportsConflicts() async throws {
        let root = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ConflictResolution(root: root, runner: Self.runner)
        let env = try await resolution.prepare(source: "agent-b", target: "agent-a")
        // "Agent" resolves; commit as finalize would.
        try write(env.path, "shared.ts", "export const value = 'from-a+from-b'\n")
        try FileManager.default.removeItem(at: try #require(env.promptPath))
        _ = try await git(["commit", "-am", "merge"], in: env.path)

        // Concurrent commit on the target in another file: clean reconciliation.
        _ = try await git(["checkout", "agent-a"], in: root)
        try write(root, "concurrent.txt", "concurrent\n")
        _ = try await git(["add", "concurrent.txt"], in: root)
        _ = try await git(["commit", "-m", "concurrent"], in: root)
        let steps = StepLog()
        let ok = try await resolution.rebaseOntoTarget(id: env.id) { steps.append($0) }
        #expect(ok == .reconciled && ok.stage == "rebase_ok")
        #expect(steps.values == [.fetchingTarget, .reconciling])
        #expect(FileManager.default.fileExists(atPath: env.path.appendingPathComponent("concurrent.txt").path))

        // Concurrent edit of the resolved file: conflict, prompt and metadata rewritten.
        try write(root, "shared.ts", "export const value = 'from-a-again'\n")
        _ = try await git(["commit", "-am", "again"], in: root)
        let conflicted = try await resolution.rebaseOntoTarget(id: env.id)
        #expect(conflicted == .conflicted([ConflictFile(path: "shared.ts", class: .typeScript)]))
        #expect(conflicted.output == "Conflicts while reconciling with the updated target: shared.ts")
        #expect(FileManager.default.fileExists(atPath: env.path.appendingPathComponent(ConflictResolution.promptFileName).path))
        #expect(try resolution.readMeta(id: env.id).conflictPaths == ["shared.ts"])

        try await resolution.preflightAbort(id: env.id)
        try await resolution.abort(id: env.id)
    }

    @Test func cancellationTerminatesGitAndCleansUp() async throws {
        let root = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        // A slow post-checkout hook makes `worktree add` hang until cancelled.
        let hook = root.appendingPathComponent(".git/hooks/post-checkout")
        try write(root.appendingPathComponent(".git/hooks"), "post-checkout", "#!/bin/sh\nsleep 30\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let resolution = ConflictResolution(root: root, runner: Self.runner)
        let started = Date()
        let task = Task { try await resolution.prepare(source: "agent-b", target: "agent-a") }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        await #expect(throws: GitError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 20)

        try FileManager.default.removeItem(at: hook)
        let envs = MergeAnalyzer.mergeEnvsDirectory(root: root)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: envs.path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(try await git(["branch", "--list", "alethe/*"], in: root).isEmpty)
    }

    @Test func promptMatchesUpstream() {
        let meta = MergeMeta(id: "abc", source: "agent-b", target: "main", projectId: nil, conflictPaths: [])
        let conflicts = [ConflictFile(path: "src/lib.rs"), ConflictFile(path: "package-lock.json")]
        let expected = """
            # Merge conflict resolution (Alethe)

            Merge from `agent-b` into `main`. This directory is an EPHEMERAL environment for this integration only.

            ## Rules (locked scope)
            - Resolve ONLY the conflicts listed below. Nothing beyond that.
            - NEVER implement features, change requirements, or change architecture.
            - Preserve the intent of BOTH branches; confirm nothing was lost.
            - When done, just save the resolved files (no commit — Alethe commits after validation).

            ## Conflicted files
            - `src/lib.rs` — Rust: Rust code: preserve both intentions; after resolving, the code must compile (cargo check).
            - `package-lock.json` — Package: package.json/lockfile: merge the dependencies; on a lockfile conflict, prefer regenerating (npm install) over hand-editing.

            Use `git diff` in this directory to see the markers (`<<<<<<<`/`>>>>>>>`).
            """
        #expect(ConflictResolution.buildPrompt(meta: meta, conflicts: conflicts) == expected)
    }

    @Test func rebaseOutcomeStagesAndIDs() throws {
        #expect(RebaseOutcome.reconciled.output == "Reconciled with the updated target — ready to reintegrate.")
        #expect(RebaseOutcome.failed("").output == "rebase_failed")
        #expect(RebaseOutcome.failed("boom").stage == "rebase_failed")
        try ConflictResolution.validateID("ab-c_1")
        #expect(throws: ConflictResolutionError.invalidEnvironmentID("")) { try ConflictResolution.validateID("") }
        #expect(throws: ConflictResolutionError.invalidEnvironmentID("a/b")) { try ConflictResolution.validateID("a/b") }
        let id = ConflictResolution.newID()
        #expect(id.count == 10)
        try ConflictResolution.validateID(id)
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [MergePrepareStep] = []
    func append(_ step: MergePrepareStep) { lock.withLock { steps.append(step) } }
    var values: [MergePrepareStep] { lock.withLock { steps } }
}
