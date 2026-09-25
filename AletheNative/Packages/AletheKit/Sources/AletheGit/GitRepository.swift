import Foundation
import Synchronization

public enum GitResetMode: String, Sendable, CaseIterable {
    case soft, mixed, hard
}

/// One repository (by its top-level directory). Operations run one at a time, in call order: an
/// actor alone would interleave across `await`s, so each call is chained after the previous one.
public actor GitRepository {
    public nonisolated let root: URL
    public nonisolated let runner: GitRunner
    private var tail: Task<Void, Never>?

    public init(root: URL, runner: GitRunner = GitRunner()) {
        self.root = root.standardizedFileURL
        self.runner = runner
    }

    // MARK: Discovery and init

    /// The top-level directory of the repository containing `path`.
    public static func discover(_ path: URL, runner: GitRunner = GitRunner()) async throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw GitError.notARepository
        }
        let directory = isDirectory.boolValue ? path : path.deletingLastPathComponent()
        let output = try await runner.run(["rev-parse", "--show-toplevel"], in: directory)
        let top = output.text.trimmingCharacters(in: .newlines)
        guard !top.isEmpty else { throw GitError.notARepository }
        return URL(fileURLWithPath: top, isDirectory: true).standardizedFileURL
    }

    /// Makes `path` a repository with a first commit of its files (upstream `git_init`); an existing
    /// repository is returned untouched.
    public static func initialize(_ path: URL, runner: GitRunner = GitRunner()) async throws -> URL {
        if let root = try? await discover(path, runner: runner) { return root }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        _ = try await runner.run(["init", "-b", "main"], in: path)
        let ignore = path.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? gitignoreSeed.write(to: ignore, atomically: true, encoding: .utf8)
        }
        _ = try await runner.run(["add", "-A"], in: path)
        let message = "Initial commit (Alethe)"
        do {
            _ = try await runner.run(["commit", "-m", message], in: path)
        } catch GitError.commandFailed {
            // No identity configured, or nothing to commit.
            _ = try await runner.run(
                ["-c", "user.name=Alethe", "-c", "user.email=alethe@localhost", "commit", "--allow-empty", "-m", message],
                in: path
            )
        }
        return try await discover(path, runner: runner)
    }

    static let gitignoreSeed = """
    node_modules/
    target/
    dist/
    build/
    .DS_Store
    .env
    .env.local

    """

    // MARK: Serial execution

    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            try Task.checkCancellation(or: .cancelled)
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs raw git arguments in the repository, serialized with the other operations.
    public func run(
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitOutput {
        let runner = runner, root = root
        return try await serialized {
            try await runner.run(arguments, in: root, allowedExitCodes: allowedExitCodes, onProgress: onProgress)
        }
    }

    private func text(_ arguments: [String]) async throws -> String {
        try await run(arguments).text
    }

    private func hasHead() async -> Bool {
        (try? await run(["rev-parse", "--verify", "-q", "HEAD"])) != nil
    }

    // MARK: Status and diff

    public func status() async throws -> GitStatus {
        GitParsers.parseStatus(try await text(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]))
    }

    /// The unified diff of one file (or all files when `path` is nil), staged or in the worktree.
    public func diff(path: String? = nil, staged: Bool = false) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--staged") }
        if let path {
            try GitParsers.validatePaths([path])
            args += ["--", path]
        }
        return try await text(args)
    }

    /// The diff of an untracked file against nothing.
    public func diffUntracked(path: String) async throws -> String {
        try GitParsers.validatePaths([path])
        return try await run(["diff", "--no-color", "--no-index", "--", "/dev/null", path], allowedExitCodes: [0, 1]).text
    }

    /// Per-file line counts: staged, worktree, or between two revisions (`from..to`).
    public func diffSummary(staged: Bool = false, range: String? = nil) async throws -> [GitDiffStat] {
        var args = ["diff", "--numstat", "-z", "-M"]
        if staged { args.append("--staged") }
        if let range {
            guard !range.hasPrefix("-") else { throw GitError.invalidArgument("range") }
            args.append(range)
        }
        return GitParsers.parseNumstat(try await text(args))
    }

    // MARK: Branches

    public func branches() async throws -> [GitBranch] {
        GitParsers.parseBranches(try await text(["for-each-ref", GitParsers.branchFormat, "refs/heads", "refs/remotes"]))
    }

    /// The current branch name, `nil` when detached.
    public func currentBranch() async throws -> String? {
        let output = try await run(["symbolic-ref", "--short", "-q", "HEAD"], allowedExitCodes: [0, 1])
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func switchBranch(_ name: String) async throws {
        try GitParsers.validateBranchName(name)
        _ = try await run(["switch", name])
    }

    /// Creates a branch at `startPoint` (HEAD when nil), switching to it when asked.
    public func createBranch(_ name: String, from startPoint: String? = nil, switchTo: Bool = true) async throws {
        try GitParsers.validateBranchName(name)
        if let startPoint { try GitParsers.validateBranchName(startPoint) }
        var args = switchTo ? ["switch", "-c", name] : ["branch", name]
        if let startPoint { args.append(startPoint) }
        _ = try await run(args)
    }

    /// A new branch at a commit from the graph, without switching (upstream `git_create_branch_from_commit`).
    public func createBranch(_ name: String, atCommit hash: String) async throws {
        try GitParsers.validateHash(hash)
        try await createBranch(name, from: hash, switchTo: false)
    }

    // MARK: Index and worktree

    public func stage(_ paths: [String]) async throws {
        try GitParsers.validatePaths(paths)
        _ = try await run(["add", "-A", "--"] + paths)
    }

    public func stageAll() async throws {
        _ = try await run(["add", "-A"])
    }

    public func unstage(_ paths: [String]) async throws {
        try GitParsers.validatePaths(paths)
        if await hasHead() {
            _ = try await run(["restore", "--staged", "--"] + paths)
        } else {
            _ = try await run(["rm", "-r", "--cached", "-q", "--"] + paths)
        }
    }

    /// Throws away worktree changes; untracked files are deleted.
    public func discard(_ paths: [String], untracked: Bool = false) async throws {
        try GitParsers.validatePaths(paths)
        if untracked {
            _ = try await run(["clean", "-f", "-q", "--"] + paths)
        } else {
            _ = try await run(["restore", "--worktree", "--"] + paths)
        }
    }

    /// Commits the index and returns the new commit hash. Amending without a message keeps the old one.
    @discardableResult
    public func commit(message: String?, amend: Bool = false) async throws -> String {
        var args = ["commit"]
        if amend { args.append("--amend") }
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-m", message]
        } else if amend {
            args.append("--no-edit")
        } else {
            throw GitError.invalidArgument("empty commit message")
        }
        _ = try await run(args)
        return try await text(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Remotes

    public func fetch(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(["fetch", "--progress", "--prune"], onProgress: onProgress).errorText
    }

    public func pull(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(["pull", "--ff-only", "--progress"], onProgress: onProgress).errorText
    }

    /// Pushes, publishing the branch to `origin` when it has no upstream yet.
    public func push(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        do {
            return try await run(["push", "--progress"], onProgress: onProgress).errorText
        } catch GitError.commandFailed(_, let stderr) where stderr.contains("no upstream") {
            return try await run(["push", "--progress", "--set-upstream", "origin", "HEAD"], onProgress: onProgress).errorText
        }
    }

    // MARK: History

    /// A page of the commit graph (branches, tags and HEAD), newest first in topological order.
    public func log(skip: Int = 0, limit: Int = 200, allRefs: Bool = true) async throws -> [GitCommit] {
        guard await hasHead() else { return [] }
        var args = ["log", GitParsers.logFormat, "--decorate=full", "--topo-order", "--skip=\(skip)", "--max-count=\(limit)"]
        if allRefs {
            args += ["--exclude=refs/heads/alethe/agent-*", "--exclude=refs/heads/alethe/merge-*", "--branches", "--tags", "--remotes"]
        }
        args.append("HEAD")
        return GitParsers.parseLog(try await text(args))
    }

    public func commitFiles(_ hash: String) async throws -> [GitFileChange] {
        try GitParsers.validateHash(hash)
        return GitParsers.parseNameStatus(
            try await text(["diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "-M", "--root", hash])
        )
    }

    public func commitMessage(_ hash: String) async throws -> String {
        try GitParsers.validateHash(hash)
        return try await text(["show", "-s", "--format=%B", hash]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cherryPick(_ hash: String) async throws {
        try GitParsers.validateHash(hash)
        _ = try await run(["cherry-pick", hash])
    }

    public func revert(_ hash: String) async throws {
        try GitParsers.validateHash(hash)
        _ = try await run(["revert", "--no-edit", hash])
    }

    public func reset(to hash: String, mode: GitResetMode) async throws {
        try GitParsers.validateHash(hash)
        _ = try await run(["reset", "--\(mode.rawValue)", hash])
    }

    /// Commits between HEAD and its upstream; `nil` when the branch tracks nothing.
    public func incomingOutgoing(limit: Int = 200) async throws -> GitIncomingOutgoing? {
        let upstream = try await run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            allowedExitCodes: [0, 128]
        )
        guard upstream.exitCode == 0 else { return nil }
        let name = upstream.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = ["log", GitParsers.logFormat, "--decorate=full", "--max-count=\(limit)"]
        let incoming = GitParsers.parseLog(try await text(base + ["HEAD..@{upstream}"]))
        let outgoing = GitParsers.parseLog(try await text(base + ["@{upstream}..HEAD"]))
        return GitIncomingOutgoing(upstream: name, incoming: incoming, outgoing: outgoing)
    }
}

/// One `GitRepository` per root, so every caller shares the same serial queue.
public final class GitRepositories: Sendable {
    public static let shared = GitRepositories()
    private let repositories = Mutex<[URL: GitRepository]>([:])

    public init() {}

    public func repository(at root: URL, runner: GitRunner = GitRunner()) -> GitRepository {
        let key = root.standardizedFileURL
        return repositories.withLock { map in
            if let existing = map[key] { return existing }
            let created = GitRepository(root: key, runner: runner)
            map[key] = created
            return created
        }
    }
}
