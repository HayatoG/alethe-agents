import Foundation

// Per-agent worktree isolation (port of upstream `worktrees.rs`, RFC-003). Each agent gets
// `<repo>/.alethe/worktrees/<agentId>/` on branch `alethe/agent-<agentId>`, either as a linked
// `git worktree` (shares the repository's `.git`) or as a `git clone --local` copy.

/// How an agent's environment is created (upstream `WorktreeMode`, persisted as `worktreeMode`).
public enum WorktreeMode: String, Codable, Sendable, CaseIterable {
    case gitWorktree
    case localCopy
}

/// Project-level multi-agent settings (upstream `Project.autoWorktree` / `Project.worktreeMode`).
public struct WorktreeSettings: Codable, Equatable, Sendable {
    /// New agent terminals get their own worktree automatically.
    public var autoWorktree: Bool
    /// `nil` means the default (`gitWorktree`), as upstream leaves the field undefined.
    public var worktreeMode: WorktreeMode?

    public init(autoWorktree: Bool = false, worktreeMode: WorktreeMode? = nil) {
        self.autoWorktree = autoWorktree
        self.worktreeMode = worktreeMode
    }

    public var effectiveMode: WorktreeMode { worktreeMode ?? .gitWorktree }

    /// The agent id a new terminal should be provisioned with, or `nil` when isolation is off or the
    /// terminal is not an agent (shells never get a worktree).
    public func agentIdForNewTerminal(isAgent: Bool, terminalId: String) -> String? {
        guard autoWorktree, isAgent, (try? GitWorktrees.sanitizeAgentId(terminalId)) != nil else { return nil }
        return terminalId.trimmingCharacters(in: .whitespaces)
    }
}

/// One agent environment under `.alethe/worktrees/` (upstream `WorktreeInfo`).
public struct WorktreeInfo: Equatable, Sendable, Codable {
    public var agentId: String
    public var path: String
    public var branch: String
    public var mode: WorktreeMode
}

/// One entry of `git worktree list --porcelain`.
public struct GitWorktreeEntry: Equatable, Sendable {
    public var path: String
    public var head: String?
    /// Short branch name (`refs/heads/` stripped); `nil` when detached or bare.
    public var branch: String?
    public var isBare = false
    public var isDetached = false
    public var isLocked = false
    public var lockReason: String?
    public var isPrunable = false
    public var prunableReason: String?

    public init(path: String) { self.path = path }

    /// The agent id when the entry is an Alethe agent worktree (branch `alethe/agent-<id>`).
    public var agentId: String? {
        guard let branch, branch.hasPrefix(GitWorktrees.branchPrefix) else { return nil }
        let id = String(branch.dropFirst(GitWorktrees.branchPrefix.count))
        return id.isEmpty ? nil : id
    }
}

/// A change `commitPending` would pick up (upstream `PendingChange`).
public struct WorktreePendingChange: Equatable, Sendable {
    public var path: String
    public var status: String
}

public enum GitWorktreeError: Error, Equatable, Sendable {
    case invalidAgentId
    case exists
    case notFound
    case invalidPath
    /// The worktree is locked through `git worktree lock` (upstream `admin_locked:<reason>`).
    case adminLocked(reason: String)
}

/// Worktree operations for one repository. Paths resolve to the main repository even when called
/// from inside a linked worktree.
public struct GitWorktrees: Sendable {
    public static let branchPrefix = "alethe/agent-"
    public static let defaultCommitMessage = "Agent work (auto-commit before integration)"

    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    // MARK: Pure helpers

    /// Agent ids become a directory and a branch name: ASCII letters, digits, `-` and `_` only.
    public static func sanitizeAgentId(_ agentId: String) throws -> String {
        let trimmed = agentId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { throw GitWorktreeError.invalidAgentId }
        return trimmed
    }

    public static func branchName(for agentId: String) -> String { branchPrefix + agentId }

    public static func worktreesBase(_ root: URL) -> URL {
        root.appendingPathComponent(".alethe", isDirectory: true).appendingPathComponent("worktrees", isDirectory: true)
    }

    /// `.git` file = linked worktree, `.git` directory = local copy, neither = not an environment.
    public static func detectMode(_ directory: URL) -> WorktreeMode? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path, isDirectory: &isDirectory)
        else { return nil }
        return isDirectory.boolValue ? .localCopy : .gitWorktree
    }

    /// Parses `git worktree list --porcelain` (blank-line separated records; `-z` output also accepted).
    public static func parsePorcelain(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var current: GitWorktreeEntry?
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\0" })
        for raw in lines {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                if let entry = current { entries.append(entry) }
                current = nil
                continue
            }
            let key: Substring, value: String?
            if let space = line.firstIndex(of: " ") {
                key = line[..<space]
                value = String(line[line.index(after: space)...])
            } else {
                key = Substring(line)
                value = nil
            }
            if key == "worktree" {
                if let entry = current { entries.append(entry) }
                current = GitWorktreeEntry(path: value ?? "")
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked":
                current?.isLocked = true
                current?.lockReason = value
            case "prunable":
                current?.isPrunable = true
                current?.prunableReason = value
            default: break
            }
        }
        if let entry = current { entries.append(entry) }
        return entries
    }

    /// Alethe infrastructure files are never agent work (upstream `is_real_work`).
    public static func isRealWork(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix(".planning/") && !path.hasPrefix(".opencode/") && path != "opencode.json"
    }

    /// Parses `git status --porcelain` (v1) into real-work changes.
    public static func parsePendingChanges(_ output: String) -> [WorktreePendingChange] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let chars = Array(line)
            let status = String(chars.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = chars.count > 3 ? String(chars[3...]).trimmingCharacters(in: .whitespaces) : ""
            return isRealWork(path) ? WorktreePendingChange(path: path, status: status) : nil
        }
    }

    // MARK: Repository resolution

    /// The main repository's top level, even when `path` is inside a linked worktree.
    public func mainRepositoryRoot(_ path: URL) async throws -> URL {
        let output = try await runner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        let common = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { throw GitError.notARepository }
        return URL(fileURLWithPath: common, isDirectory: true).resolvingSymlinksInPath()
            .deletingLastPathComponent().standardizedFileURL
    }

    private func environment(_ repo: URL, _ agentId: String) async throws -> (root: URL, id: String, dir: URL) {
        let root = try await mainRepositoryRoot(repo)
        let id = try Self.sanitizeAgentId(agentId)
        return (root, id, Self.worktreesBase(root).appendingPathComponent(id, isDirectory: true))
    }

    // MARK: Operations

    /// Creates the agent's environment on a new `alethe/agent-<id>` branch at HEAD.
    public func provision(repo: URL, agentId: String, mode: WorktreeMode) async throws -> WorktreeInfo {
        let (root, id, dest) = try await environment(repo, agentId)
        try FileManager.default.createDirectory(at: Self.worktreesBase(root), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw GitWorktreeError.exists }
        let branch = Self.branchName(for: id)
        switch mode {
        case .gitWorktree:
            _ = try await runner.run(["worktree", "add", "-b", branch, dest.path, "HEAD"], in: root)
        case .localCopy:
            _ = try await runner.run(["clone", "--local", "--", root.path, dest.path], in: root)
            _ = try await runner.run(["checkout", "-b", branch], in: dest)
        }
        return WorktreeInfo(agentId: id, path: dest.path, branch: branch, mode: mode)
    }

    /// The agent environments under `.alethe/worktrees/`, sorted by agent id.
    public func list(repo: URL) async throws -> [WorktreeInfo] {
        let root = try await mainRepositoryRoot(repo)
        let base = Self.worktreesBase(root)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        var result: [WorktreeInfo] = []
        for dir in children {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let mode = Self.detectMode(dir) else { continue }
            let head = try? await runner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
            let branch = head?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(WorktreeInfo(agentId: dir.lastPathComponent, path: dir.path, branch: branch, mode: mode))
        }
        return result.sorted { $0.agentId < $1.agentId }
    }

    /// Every worktree git knows about (`git worktree list --porcelain`), including the main one.
    public func gitWorktrees(repo: URL) async throws -> [GitWorktreeEntry] {
        let root = try await mainRepositoryRoot(repo)
        return Self.parsePorcelain(try await runner.run(["worktree", "list", "--porcelain"], in: root).text)
    }

    /// Removes the environment; a locked linked worktree reports its lock reason instead.
    public func remove(repo: URL, agentId: String, force: Bool) async throws {
        let (root, _, dest) = try await environment(repo, agentId)
        guard FileManager.default.fileExists(atPath: dest.path) else { throw GitWorktreeError.notFound }
        let base = Self.worktreesBase(root).resolvingSymlinksInPath().path + "/"
        let resolved = dest.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base) else { throw GitWorktreeError.invalidPath }
        if Self.detectMode(dest) == .gitWorktree {
            if let reason = Self.adminLockReason(dest) { throw GitWorktreeError.adminLocked(reason: reason) }
            _ = try await runner.run(["worktree", "remove"] + (force ? ["--force"] : []) + [resolved.path], in: root)
        } else {
            try FileManager.default.removeItem(at: resolved)
        }
    }

    public func lock(repo: URL, agentId: String, reason: String? = nil) async throws {
        let (root, _, dest) = try await environment(repo, agentId)
        guard FileManager.default.fileExists(atPath: dest.path) else { throw GitWorktreeError.notFound }
        var args = ["worktree", "lock"]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            args += ["--reason", reason]
        }
        _ = try await runner.run(args + [dest.path], in: root)
    }

    public func unlock(repo: URL, agentId: String) async throws {
        let (root, _, dest) = try await environment(repo, agentId)
        guard FileManager.default.fileExists(atPath: dest.path) else { throw GitWorktreeError.notFound }
        _ = try await runner.run(["worktree", "unlock", dest.path], in: root)
    }

    /// Brings a local copy's agent branch into the main repository; linked worktrees already share it.
    public func fetchBranch(repo: URL, agentId: String) async throws {
        let (root, id, dir) = try await environment(repo, agentId)
        switch Self.detectMode(dir) {
        case .localCopy:
            let branch = Self.branchName(for: id)
            _ = try await runner.run(["fetch", dir.path, "+refs/heads/\(branch):refs/heads/\(branch)"], in: root)
        case .gitWorktree:
            return
        case nil:
            throw GitWorktreeError.notFound
        }
    }

    /// Real-work changes in the environment, without touching it.
    public func pendingChanges(repo: URL, agentId: String) async throws -> [WorktreePendingChange] {
        let dir = try await existingEnvironment(repo, agentId)
        return Self.parsePendingChanges(try await runner.run(["status", "--porcelain"], in: dir).text)
    }

    /// Commits the real-work changes; returns `false` when there was nothing to commit. A blank
    /// message falls back to the upstream auto-commit message.
    @discardableResult
    public func commitPending(repo: URL, agentId: String, message: String = GitWorktrees.defaultCommitMessage) async throws -> Bool {
        let dir = try await existingEnvironment(repo, agentId)
        let changes = Self.parsePendingChanges(try await runner.run(["status", "--porcelain"], in: dir).text)
        guard !changes.isEmpty else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultCommitMessage : message
        _ = try await runner.run(["add", "--"] + changes.map(\.path), in: dir)
        _ = try await runner.run(["commit", "-m", text], in: dir)
        return true
    }

    /// Deletes leftover directories under `.alethe/worktrees/` that are no longer environments, then
    /// prunes worktree metadata whose directory is gone. Returns the removed agent ids.
    @discardableResult
    public func cleanup(repo: URL) async throws -> [String] {
        let root = try await mainRepositoryRoot(repo)
        let base = Self.worktreesBase(root)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        var removed: [String] = []
        for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard Self.detectMode(dir) == nil, (try? Self.sanitizeAgentId(dir.lastPathComponent)) != nil else { continue }
            try FileManager.default.removeItem(at: dir)
            removed.append(dir.lastPathComponent)
        }
        _ = try await runner.run(["worktree", "prune"], in: root)
        return removed.sorted()
    }

    private func existingEnvironment(_ repo: URL, _ agentId: String) async throws -> URL {
        let (_, _, dir) = try await environment(repo, agentId)
        guard Self.detectMode(dir) != nil else { throw GitWorktreeError.notFound }
        return dir
    }

    /// The `git worktree lock` reason of a linked worktree (its admin dir's `locked` file).
    static func adminLockReason(_ worktree: URL) -> String? {
        guard let pointer = try? String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8),
              let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let adminDir = gitdir.hasPrefix("/") ? URL(fileURLWithPath: gitdir) : worktree.appendingPathComponent(gitdir)
        let locked = adminDir.appendingPathComponent("locked")
        guard FileManager.default.fileExists(atPath: locked.path) else { return nil }
        let reason = ((try? String(contentsOf: locked, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "no reason given" : reason
    }
}
