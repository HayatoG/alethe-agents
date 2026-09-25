import AletheGit
import Foundation

public enum MergeError: Error, Equatable, Sendable {
    case branchNotFound(String)
    case invalidBranch(String)
}

/// Trial-merges one branch into another in a disposable detached worktree under
/// `.alethe/merge-envs/`, so the user's working tree is never touched (upstream `merge_analyze`).
public struct MergeAnalyzer: Sendable {
    public let root: URL
    public let runner: GitRunner

    public init(root: URL, runner: GitRunner = GitRunner()) {
        self.root = root
        self.runner = runner
    }

    public static func mergeEnvsDirectory(root: URL) -> URL {
        root.appendingPathComponent(".alethe/merge-envs", isDirectory: true)
    }

    public func analyze(source: String, target: String) async throws -> MergeAnalysis {
        try await ensureBranch(source)
        try await ensureBranch(target)

        let envs = Self.mergeEnvsDirectory(root: root)
        try FileManager.default.createDirectory(at: envs, withIntermediateDirectories: true)
        let env = envs.appendingPathComponent("analyze-\(Self.shortID())", isDirectory: true)

        _ = try await runner.run(["worktree", "add", "--detach", env.path, target], in: root)
        do {
            let merge = try await runner.run(
                ["merge", "--no-commit", "--no-ff", source], in: env, allowedExitCodes: [0, 1])
            let clean = merge.exitCode == 0
            let conflicts = clean ? [] : try await unmergedFiles(in: env).map { ConflictFile(path: $0) }
            await teardown(env)
            return MergeAnalysis(clean: clean, source: source, target: target, conflicts: conflicts)
        } catch {
            await teardown(env)
            throw error
        }
    }

    /// Paths left unmerged (`--diff-filter=U`) in a conflicted worktree.
    public func unmergedFiles(in directory: URL) async throws -> [String] {
        let output = try await runner.run(["diff", "--name-only", "--diff-filter=U", "-z"], in: directory)
        return output.text.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    func ensureBranch(_ branch: String) async throws {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { throw MergeError.invalidBranch(branch) }
        let output = try await runner.run(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root, allowedExitCodes: [0, 1, 128])
        guard output.exitCode == 0 else { throw MergeError.branchNotFound(branch) }
    }

    /// Best-effort: a clean uncommitted merge also leaves staged state that `remove --force` discards.
    private func teardown(_ env: URL) async {
        _ = try? await runner.run(["merge", "--abort"], in: env, allowedExitCodes: [0, 1, 128])
        _ = try? await runner.run(["worktree", "remove", "--force", env.path], in: root)
    }

    private static func shortID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
