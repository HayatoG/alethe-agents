import Foundation
import AletheGit

/// Where one delegated job works: the folder it was given, or its own worktree.
struct JobWorkspace: Hashable, Sendable {
    var jobID: String
    var cwd: String
    /// Set when the job runs isolated; the same path as `cwd` then.
    var worktree: String?
}

extension OrchestratorCore {
    /// The folder each job of a batch works in. With `isolate`, one git worktree per job on
    /// upstream's path and branch (`<repo>/.alethe/worktrees/<job>/`, `alethe/agent-<job>`), made
    /// outside the actor's isolation so git never stalls a running worker.
    func workspaces(for ids: [String], request: DelegateRequest) async throws(OrchestratorToolError) -> [JobWorkspace] {
        guard request.isolate else {
            return ids.map { JobWorkspace(jobID: $0, cwd: request.cwd, worktree: nil) }
        }
        return try await Self.makeWorktrees(for: ids, repo: request.cwd, worktrees: configuration.worktrees)
    }

    /// A batch is accepted whole or not at all: when one worktree cannot be made, the ones already
    /// made are removed (with their branches) before the refusal.
    @concurrent
    static func makeWorktrees(for ids: [String], repo: String, worktrees: GitWorktrees) async throws(OrchestratorToolError) -> [JobWorkspace] {
        let folder = URL(fileURLWithPath: repo, isDirectory: true)
        var made: [JobWorkspace] = []
        for id in ids {
            do {
                let info = try await worktrees.provision(repo: folder, agentId: id, mode: .gitWorktree)
                made.append(JobWorkspace(jobID: id, cwd: info.path, worktree: info.path))
            } catch {
                await removeWorktrees(made, repo: repo, worktrees: worktrees)
                throw OrchestratorToolError("isolate needs a git repository at \(repo): \(describe(error, jobID: id))")
            }
        }
        return made
    }

    /// Removes the worktrees of a batch that was not accepted, and their branches. Best effort:
    /// nothing else refers to them yet.
    @concurrent
    static func removeWorktrees(_ workspaces: [JobWorkspace], repo: String, worktrees: GitWorktrees) async {
        let folder = URL(fileURLWithPath: repo, isDirectory: true)
        let isolated = workspaces.filter { $0.worktree != nil }
        guard !isolated.isEmpty, let root = try? await worktrees.mainRepositoryRoot(folder) else { return }
        for workspace in isolated {
            try? await worktrees.remove(repo: folder, agentId: workspace.jobID, force: true)
            _ = try? await worktrees.runner.run(["branch", "-D", GitWorktrees.branchName(for: workspace.jobID)], in: root)
        }
    }

    private static func describe(_ error: any Error, jobID: String) -> String {
        switch error {
        case GitError.notARepository: "not a git repository"
        case GitError.gitMissing: "git not available"
        case GitError.commandFailed(_, let stderr): stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case GitWorktreeError.exists: "a worktree already exists for \(jobID)"
        default: String(describing: error)
        }
    }
}
