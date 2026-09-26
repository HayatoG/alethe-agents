import AletheGit
import Foundation

/// The steps of applying a worker's worktree, in order.
public enum WorktreeApplyStep: String, Sendable, Hashable, CaseIterable {
    case committing, fetching, analyzing, preparing, finalizing

    /// Cancel is honoured until the merge into the target starts.
    public var isCancelable: Bool { self != .finalizing }
}

/// What an apply will change, shown before the person confirms it.
public struct WorktreeApplyPreview: Sendable, Hashable {
    /// The main repository the worktree belongs to.
    public var root: URL
    public var agentID: String
    /// `alethe/agent-<job>`.
    public var source: String
    /// The branch checked out in the main repository: the one that changes.
    public var target: String
    /// Uncommitted work in the worktree, committed first.
    public var pending: [String]
    /// Files the agent branch already changes relative to the target.
    public var committed: [String]

    public init(root: URL, agentID: String, source: String, target: String, pending: [String], committed: [String]) {
        self.root = root
        self.agentID = agentID
        self.source = source
        self.target = target
        self.pending = pending
        self.committed = committed
    }

    /// Every file the apply touches, sorted.
    public var files: [String] { Array(Set(pending + committed)).sorted() }
}

public enum WorktreeApplyOutcome: Sendable, Hashable {
    /// Merged into the target; the merge environment is gone.
    case applied
    /// The branches conflict: a merge environment was prepared for the Merge Center.
    case conflicted(environmentID: String)
    /// Finalizing stopped (markers, validation, target moved, diverged…); the environment is kept.
    case notMerged(environmentID: String, stage: MergeFinishOutcome.Stage, output: String)
    /// The agent branch adds nothing to the target.
    case nothingToApply
    /// Stopped before the merge step; nothing was integrated.
    case cancelled
}

public struct WorktreeApplyResult: Sendable, Hashable {
    public var outcome: WorktreeApplyOutcome
    /// Whether pending work was committed in the worktree first.
    public var committedPending: Bool
    public var analysis: MergeAnalysis?
    public var environment: ConflictEnvironment?

    public init(outcome: WorktreeApplyOutcome, committedPending: Bool = false,
                analysis: MergeAnalysis? = nil, environment: ConflictEnvironment? = nil) {
        self.outcome = outcome
        self.committedPending = committedPending
        self.analysis = analysis
        self.environment = environment
    }
}

public enum WorktreeApplyError: Error, Equatable, Sendable {
    /// The main repository has no branch checked out.
    case detachedTarget
    /// The main repository is on the agent's own branch.
    case sameBranch(String)
}

/// The git operations an apply runs, replaceable in tests.
public struct WorktreeApplyOperations: Sendable {
    public var mainRoot: @Sendable (_ worktree: URL) async throws -> URL
    public var currentBranch: @Sendable (_ root: URL) async throws -> String?
    public var pendingChanges: @Sendable (_ root: URL, _ agentID: String) async throws -> [String]
    public var committedFiles: @Sendable (_ root: URL, _ source: String, _ target: String) async -> [String]
    public var commitPending: @Sendable (_ root: URL, _ agentID: String, _ message: String) async throws -> Bool
    public var fetchBranch: @Sendable (_ root: URL, _ agentID: String) async throws -> Void
    public var analyze: @Sendable (_ root: URL, _ source: String, _ target: String) async throws -> MergeAnalysis
    public var prepare: @Sendable (_ root: URL, _ source: String, _ target: String, _ projectID: String?) async throws -> ConflictEnvironment
    public var finalize: @Sendable (_ root: URL, _ handle: MergeEnvHandle) async throws -> MergeFinishOutcome
    public var abort: @Sendable (_ root: URL, _ handle: MergeEnvHandle) async throws -> Void

    public init(
        mainRoot: @escaping @Sendable (URL) async throws -> URL,
        currentBranch: @escaping @Sendable (URL) async throws -> String?,
        pendingChanges: @escaping @Sendable (URL, String) async throws -> [String],
        committedFiles: @escaping @Sendable (URL, String, String) async -> [String],
        commitPending: @escaping @Sendable (URL, String, String) async throws -> Bool,
        fetchBranch: @escaping @Sendable (URL, String) async throws -> Void,
        analyze: @escaping @Sendable (URL, String, String) async throws -> MergeAnalysis,
        prepare: @escaping @Sendable (URL, String, String, String?) async throws -> ConflictEnvironment,
        finalize: @escaping @Sendable (URL, MergeEnvHandle) async throws -> MergeFinishOutcome,
        abort: @escaping @Sendable (URL, MergeEnvHandle) async throws -> Void
    ) {
        self.mainRoot = mainRoot
        self.currentBranch = currentBranch
        self.pendingChanges = pendingChanges
        self.committedFiles = committedFiles
        self.commitPending = commitPending
        self.fetchBranch = fetchBranch
        self.analyze = analyze
        self.prepare = prepare
        self.finalize = finalize
        self.abort = abort
    }

    /// The Merge Center's own analyzer, environment and finisher (P4-9…P4-13). Finalizing runs no
    /// validation commands, as upstream's apply; the Merge Center has them when a merge stops.
    public static func live(runner: GitRunner = GitRunner()) -> WorktreeApplyOperations {
        let worktrees = GitWorktrees(runner: runner)
        return WorktreeApplyOperations(
            mainRoot: { try await worktrees.mainRepositoryRoot($0) },
            currentBranch: { try await GitRepository(root: $0, runner: runner).currentBranch() },
            pendingChanges: { try await worktrees.pendingChanges(repo: $0, agentId: $1).map(\.path) },
            committedFiles: { root, source, target in
                // A local copy's branch is not in the main repository until it is fetched: none yet.
                let output = try? await runner.run(["diff", "--name-only", "-z", "\(target)...\(source)", "--"],
                                                   in: root, allowedExitCodes: [0])
                return output?.text.split(separator: "\0").map(String.init).filter { !$0.isEmpty } ?? []
            },
            commitPending: { try await worktrees.commitPending(repo: $0, agentId: $1, message: $2) },
            fetchBranch: { try await worktrees.fetchBranch(repo: $0, agentId: $1) },
            analyze: { try await MergeAnalyzer(root: $0, runner: runner).analyze(source: $1, target: $2) },
            prepare: { try await ConflictResolution(root: $0, runner: runner).prepare(source: $1, target: $2, projectId: $3) },
            finalize: { try await MergeFinisher(root: $0, runner: runner).finalize($1, settings: ValidationSettings(), healthProbe: nil) },
            abort: { try await MergeFinisher(root: $0, runner: runner).abort($1) }
        )
    }
}

/// Applies a finished worker's worktree into the branch checked out in its repository (upstream
/// `OrchestratorPane` `applyWorktree`): commits the worktree's pending work, fetches the branch of a
/// local copy, trial-merges it, then prepares and finalizes the merge. A conflict or a stopped
/// finalize leaves a merge environment for the Merge Center. Cancelling the calling task stops the
/// apply at the next step boundary until the merge step; commit, fetch and finalize are never
/// interrupted halfway.
public struct WorktreeApply: Sendable {
    public let operations: WorktreeApplyOperations

    public init(operations: WorktreeApplyOperations = .live()) {
        self.operations = operations
    }

    /// Upstream's commit message for the worktree's pending work.
    public static func commitMessage(jobID: String) -> String { "Alethe orchestrator: \(jobID)" }

    /// What applying `worktree` would change; nothing is written.
    public func preview(worktree: URL, agentID: String) async throws -> WorktreeApplyPreview {
        let id = try GitWorktrees.sanitizeAgentId(agentID)
        let root = try await operations.mainRoot(worktree)
        guard let target = try await operations.currentBranch(root), !target.isEmpty else {
            throw WorktreeApplyError.detachedTarget
        }
        let source = GitWorktrees.branchName(for: id)
        guard source != target else { throw WorktreeApplyError.sameBranch(target) }
        let pending = try await operations.pendingChanges(root, id)
        let committed = await operations.committedFiles(root, source, target)
        return WorktreeApplyPreview(root: root, agentID: id, source: source, target: target,
                                    pending: pending, committed: committed)
    }

    public func run(_ preview: WorktreeApplyPreview, projectID: String? = nil,
                    progress: @escaping @Sendable (WorktreeApplyStep) -> Void = { _ in }) async throws -> WorktreeApplyResult {
        let ops = operations
        let (root, id, source, target) = (preview.root, preview.agentID, preview.source, preview.target)
        var result = WorktreeApplyResult(outcome: .cancelled)
        do {
            guard !Task.isCancelled else { return result }
            progress(.committing)
            let message = Self.commitMessage(jobID: id)
            result.committedPending = try await Self.shielded { try await ops.commitPending(root, id, message) }

            guard !Task.isCancelled else { return result }
            progress(.fetching)
            // Upstream ignores a failed fetch: a linked worktree already shares the branch.
            try? await Self.shielded { try await ops.fetchBranch(root, id) }

            guard !Task.isCancelled else { return result }
            progress(.analyzing)
            let analysis = try await ops.analyze(root, source, target)
            result.analysis = analysis

            guard !Task.isCancelled else { return result }
            progress(.preparing)
            let environment = try await ops.prepare(root, source, target, projectID)
            result.environment = environment
            let handle = MergeEnvHandle(id: environment.id, source: source, target: target,
                                        conflictPaths: environment.conflicts.map(\.path))
            if !analysis.clean || !environment.clean {
                result.outcome = .conflicted(environmentID: environment.id)
                return result
            }
            guard !Task.isCancelled else {
                try? await Self.shielded { try await ops.abort(root, handle) }
                result.environment = nil
                return result
            }

            progress(.finalizing)
            let finished = try await Self.shielded { try await ops.finalize(root, handle) }
            if finished.merged {
                result.outcome = .applied
            } else if finished.stage == .nothingToIntegrate {
                try? await Self.shielded { try await ops.abort(root, handle) }
                result.environment = nil
                result.outcome = .nothingToApply
            } else {
                result.outcome = .notMerged(environmentID: environment.id, stage: finished.stage, output: finished.output)
            }
            return result
        } catch {
            // Analysis and prepare clean up after themselves when cancelled.
            if Task.isCancelled { return WorktreeApplyResult(outcome: .cancelled, committedPending: result.committedPending) }
            throw error
        }
    }

    /// Runs `operation` without the caller's cancellation, so its git process is never killed halfway.
    static func shielded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached { try await operation() }.value
    }
}
