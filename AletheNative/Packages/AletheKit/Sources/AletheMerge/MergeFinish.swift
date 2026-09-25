import AletheGit
import Foundation

public enum MergeFinishError: Error, Equatable, Sendable {
    case invalidEnvironmentID(String)
    case environmentNotFound
    /// A path that would resolve outside the allowed base directory.
    case invalidPath
}

/// A merge environment prepared under `.alethe/merge-envs/<id>` on branch `alethe/merge-<id>`
/// (upstream `merge_prepare` layout).
public struct MergeEnvHandle: Codable, Hashable, Sendable {
    public var id: String
    public var source: String
    public var target: String
    /// Files that were conflicted at prepare time; scanned for leftover markers before finishing.
    public var conflictPaths: [String]

    public init(id: String, source: String, target: String, conflictPaths: [String] = []) {
        self.id = id
        self.source = source
        self.target = target
        self.conflictPaths = conflictPaths
    }

    public var branch: String { "alethe/merge-\(id)" }
    public func directory(root: URL) -> URL {
        MergeAnalyzer.mergeEnvsDirectory(root: root).appendingPathComponent(id, isDirectory: true)
    }
    public func metadataFile(root: URL) -> URL {
        MergeAnalyzer.mergeEnvsDirectory(root: root).appendingPathComponent("\(id).json")
    }

    /// Upstream `validate_env_id`: ASCII alphanumerics, `-` and `_` only.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

/// Upstream `MergeOutcome` — `stage` mirrors upstream strings so persisted history reads the same.
public struct MergeFinishOutcome: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case conflictMarkers = "conflict_markers"
        case unmerged
        case validation
        case validated
        case targetNotCheckedOut = "target_not_checked_out"
        case nothingToIntegrate = "nothing_to_integrate"
        case branchDiverged = "branch_diverged"
        case integration
        case merged
    }

    public var merged: Bool
    public var stage: Stage
    public var output: String
    public var validation: ValidationReport?
    /// API contract warnings (upstream shield layer 3); `nil` when the check did not run.
    public var contractWarnings: [ContractWarning]? = nil

    public init(merged: Bool, stage: Stage, output: String, validation: ValidationReport? = nil,
                contractWarnings: [ContractWarning]? = nil) {
        self.merged = merged
        self.stage = stage
        self.output = output
        self.validation = validation
        self.contractWarnings = contractWarnings
    }

    public var validationRan: Bool { validation?.ranAnyCommand ?? false }
}

/// Upstream `ForceCleanupResult`. Force cleanup deletes files, so the UI must confirm it once first.
public struct MergeForceCleanupResult: Codable, Equatable, Sendable {
    public var deleted: Bool
    public var pruned: Bool
    public static let requiresConfirmation = true
}

/// One pending change in a worktree (`git status --porcelain`).
public struct WorktreePendingChange: Codable, Equatable, Sendable {
    public var status: String
    public var path: String
}

/// Validate, finalize, abort and clean up a merge environment (upstream `conflict_resolution.rs`
/// finish commands and `worktrees.rs` commit/remove). The user's working tree only ever moves by
/// fast-forward of the checked-out target branch.
public struct MergeFinisher: Sendable {
    public static let promptFile = "ALETHE_CONFLICT.md"

    public let root: URL
    public let runner: GitRunner
    public let validator: ValidationRunner

    public init(root: URL, runner: GitRunner = GitRunner(), validator: ValidationRunner = ValidationRunner()) {
        self.root = root
        self.runner = runner
        self.validator = validator
    }

    // MARK: Validate

    /// Markers → stage everything → validation pipeline; never commits (upstream `merge_validate`).
    public func validate(_ env: MergeEnvHandle, settings: ValidationSettings) async throws -> MergeFinishOutcome {
        let dir = try existingDirectory(env)
        var outcome = try await validateAndStage(env, dir: dir, settings: settings)
            ?? MergeFinishOutcome(merged: false, stage: .validated, output: "", validation: nil)
        if outcome.stage == .validated { outcome.contractWarnings = Self.contractWarnings(in: dir) }
        return outcome
    }

    /// Best-effort: a failing check is an empty list, never a blocker (upstream `unwrap_or_default`).
    static func contractWarnings(in dir: URL) -> [ContractWarning] {
        (try? ContractCheck.check(root: dir)) ?? []
    }

    /// Returns a blocking outcome, or a `.validated` one carrying the report.
    private func validateAndStage(_ env: MergeEnvHandle, dir: URL, settings: ValidationSettings) async throws -> MergeFinishOutcome? {
        let markers = Self.leftoverMarkers(in: dir, paths: env.conflictPaths)
        if !markers.isEmpty {
            return MergeFinishOutcome(merged: false, stage: .conflictMarkers,
                                      output: "Conflict markers remaining in: \(markers.joined(separator: ", "))")
        }
        // The prompt file must leave before `add -A`, or it lands in the merge commit.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.promptFile))
        _ = try await runner.run(["add", "-A"], in: dir)
        let still = try await MergeAnalyzer(root: root, runner: runner).unmergedFiles(in: dir)
        if !still.isEmpty {
            return MergeFinishOutcome(merged: false, stage: .unmerged,
                                      output: "Unresolved files: \(still.joined(separator: ", "))")
        }
        let report = await validator.run(settings.effectiveCommands, in: dir)
        switch report.status {
        case .failed, .cancelled:
            let step = report.steps.last
            return MergeFinishOutcome(merged: false, stage: .validation,
                                      output: step.map { "\($0.command)\n\($0.output)" } ?? "Validation cancelled",
                                      validation: report)
        case .passed, .unverified:
            let text = report.status == .passed
                ? "Validation passed — ready to integrate."
                : "No validation command configured — nothing was checked (not a blocker)."
            return MergeFinishOutcome(merged: false, stage: .validated, output: text, validation: report)
        }
    }

    // MARK: Finalize

    /// Revalidates, commits the staged merge, fast-forwards the checked-out target and tears the
    /// environment down (upstream `merge_finalize`). Any non-merged outcome preserves the environment.
    public func finalize(_ env: MergeEnvHandle, settings: ValidationSettings = ValidationSettings(),
                         healthProbe: HealthProbe? = HealthProbe()) async throws -> MergeFinishOutcome {
        let dir = try existingDirectory(env)
        guard var outcome = try await validateAndStage(env, dir: dir, settings: settings) else {
            throw MergeFinishError.environmentNotFound
        }
        guard outcome.stage == .validated else { return outcome }
        let contract = Self.contractWarnings(in: dir)
        outcome.contractWarnings = contract

        if let probe = healthProbe, let command = settings.healthCheckCommand,
           !command.trimmingCharacters(in: .whitespaces).isEmpty {
            outcome.validation?.healthProbe = try? await probe.run(in: dir, startCommand: command, path: settings.healthCheckPath)
        }

        let message = "merge(alethe): \(env.source) -> \(env.target)"
        let staged = try await runner.run(["diff", "--cached", "--quiet"], in: dir, allowedExitCodes: [0, 1])
        if staged.exitCode == 1 {
            let files = try await runner.run(["diff", "--cached", "--name-only"], in: dir).text
                .split(separator: "\n").map(String.init)
            let hasHead = try await runner.run(["rev-parse", "--verify", "-q", "HEAD"], in: dir, allowedExitCodes: [0, 1]).exitCode == 0
            if files == [Self.promptFile] && hasHead {
                _ = try await runner.run(["commit", "--amend", "--no-edit"], in: dir)
            } else {
                _ = try await runner.run(["commit", "-m", message], in: dir)
            }
        }

        let head = (try? await runner.run(["symbolic-ref", "--short", "HEAD"], in: root).text
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard head == env.target else {
            return MergeFinishOutcome(
                merged: false, stage: .targetNotCheckedOut,
                output: "The target branch '\(env.target)' is not checked out in the repository (current: '\(head)'). Check it out and finalize again.",
                validation: outcome.validation)
        }
        let branchSHA = try await revParse("HEAD", in: dir)
        let targetSHA = try await revParse("HEAD", in: root)
        if !branchSHA.isEmpty && branchSHA == targetSHA {
            return MergeFinishOutcome(
                merged: false, stage: .nothingToIntegrate,
                output: "Nothing to integrate — the branch has no changes relative to the target branch.",
                validation: outcome.validation)
        }
        let ff = try await runner.run(["merge", "--ff-only", env.branch], in: root, allowedExitCodes: [0, 1, 128])
        if ff.exitCode != 0 {
            let error = ff.errorText
            let lower = error.lowercased()
            let diverged = lower.contains("not possible to fast-forward") || lower.contains("non-fast-forward")
            return MergeFinishOutcome(merged: false, stage: diverged ? .branchDiverged : .integration,
                                      output: error, validation: outcome.validation)
        }

        await teardown(env, deleteBranch: "-d")
        return MergeFinishOutcome(merged: true, stage: .merged, output: message, validation: outcome.validation,
                                  contractWarnings: contract)
    }

    // MARK: Abort / cleanup

    /// Destroys the environment without integrating (upstream `merge_abort`); idempotent.
    public func abort(_ env: MergeEnvHandle) async throws {
        guard MergeEnvHandle.isValidID(env.id) else { throw MergeFinishError.invalidEnvironmentID(env.id) }
        await teardown(env, deleteBranch: "-D")
    }

    /// Clears an unfinished merge/rebase inside the environment only (upstream `merge_preflight_abort`);
    /// "nothing in progress" is a no-op, anything else propagates.
    public func preflightAbort(_ env: MergeEnvHandle) async throws {
        let dir = try existingDirectory(env)
        for args in [["merge", "--abort"], ["rebase", "--abort"]] {
            let out = try await runner.run(args, in: dir, allowedExitCodes: Set(0...255))
            guard out.exitCode != 0 else { continue }
            let lower = out.errorText.lowercased()
            if lower.contains("no merge") || lower.contains("no rebase") { continue }
            throw GitError.commandFailed(exitCode: out.exitCode, stderr: out.errorText)
        }
    }

    /// Deletes the environment directory outright, then `worktree prune` (upstream `merge_force_cleanup`).
    /// Destructive: callers confirm once (`MergeForceCleanupResult.requiresConfirmation`).
    public func forceCleanup(_ env: MergeEnvHandle) async throws -> MergeForceCleanupResult {
        guard MergeEnvHandle.isValidID(env.id) else { throw MergeFinishError.invalidEnvironmentID(env.id) }
        let fm = FileManager.default
        let dir = env.directory(root: root)
        var deleted = true
        if fm.fileExists(atPath: dir.path) {
            let base = MergeAnalyzer.mergeEnvsDirectory(root: root).resolvingSymlinksInPath().path + "/"
            guard dir.resolvingSymlinksInPath().path.hasPrefix(base) else { throw MergeFinishError.invalidPath }
            deleted = (try? fm.removeItem(at: dir)) != nil
        }
        let pruned = (try? await runner.run(["worktree", "prune"], in: root)) != nil
        try? fm.removeItem(at: env.metadataFile(root: root))
        return MergeForceCleanupResult(deleted: deleted, pruned: pruned)
    }

    // MARK: Worktree commit / removal

    /// Pending real work in a worktree; agent scaffolding (`.planning/`, `.opencode/`, `opencode.json`)
    /// is ignored as upstream `is_real_work`. Shown by the confirm-commit sheet before integrating.
    public func pendingChanges(in worktree: URL) async throws -> [WorktreePendingChange] {
        let out = try await runner.run(["status", "--porcelain"], in: worktree)
        return Self.parsePorcelain(out.text)
    }

    /// Commits all pending work with the user-confirmed message; `false` when nothing was pending
    /// (upstream `worktree_commit_worktree`).
    @discardableResult
    public func commitPending(in worktree: URL, message: String) async throws -> Bool {
        guard try await !pendingChanges(in: worktree).isEmpty else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["add", "-A"], in: worktree)
        _ = try await runner.run(["commit", "-m", text.isEmpty ? "Agent work (auto-commit before integration)" : text], in: worktree)
        return true
    }

    /// Removes an agent worktree after its branch was merged; `force` discards uncommitted work.
    /// Only paths inside `<repo>/.alethe/worktrees` are accepted (upstream `worktree_remove`).
    public func removeWorktree(at worktree: URL, force: Bool = false) async throws {
        let base = root.appendingPathComponent(".alethe/worktrees", isDirectory: true).resolvingSymlinksInPath().path + "/"
        let path = worktree.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { throw MergeFinishError.invalidPath }
        guard FileManager.default.fileExists(atPath: path) else { throw MergeFinishError.environmentNotFound }
        _ = try await runner.run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: root)
        _ = try? await runner.run(["worktree", "prune"], in: root)
    }

    // MARK: Helpers

    static func parsePorcelain(_ text: String) -> [WorktreePendingChange] {
        text.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let noise = path.hasPrefix(".planning/") || path.hasPrefix(".opencode/") || path == "opencode.json"
            return path.isEmpty || noise ? nil : WorktreePendingChange(status: status, path: path)
        }
    }

    static func leftoverMarkers(in dir: URL, paths: [String]) -> [String] {
        paths.filter { rel in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) else { return false }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") }
        }
    }

    private func existingDirectory(_ env: MergeEnvHandle) throws -> URL {
        guard MergeEnvHandle.isValidID(env.id) else { throw MergeFinishError.invalidEnvironmentID(env.id) }
        let dir = env.directory(root: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw MergeFinishError.environmentNotFound
        }
        return dir
    }

    private func revParse(_ rev: String, in dir: URL) async throws -> String {
        try await runner.run(["rev-parse", rev], in: dir).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func teardown(_ env: MergeEnvHandle, deleteBranch flag: String) async {
        _ = try? await runner.run(["worktree", "remove", "--force", env.directory(root: root).path], in: root)
        _ = try? await runner.run(["branch", flag, env.branch], in: root)
        try? FileManager.default.removeItem(at: env.metadataFile(root: root))
    }
}
