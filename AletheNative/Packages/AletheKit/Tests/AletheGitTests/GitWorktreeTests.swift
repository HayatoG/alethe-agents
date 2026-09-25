import Foundation
import Testing
@testable import AletheGit

@Suite struct GitWorktreeTests {
    // MARK: U — pure

    @Test func parsesPorcelainList() {
        let output = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo/.alethe/worktrees/a1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/alethe/agent-a1
        locked waiting for review

        worktree /tmp/gone
        HEAD 3333333333333333333333333333333333333333
        detached
        locked
        prunable gitdir file points to non-existent location

        """
        let entries = GitWorktrees.parsePorcelain(output)
        #expect(entries.count == 3)
        #expect(entries[0].path == "/repo" && entries[0].branch == "main" && entries[0].agentId == nil)
        #expect(entries[1].agentId == "a1" && entries[1].isLocked && entries[1].lockReason == "waiting for review")
        #expect(entries[2].isDetached && entries[2].branch == nil && entries[2].isLocked && entries[2].lockReason == nil)
        #expect(entries[2].isPrunable && entries[2].prunableReason == "gitdir file points to non-existent location")
    }

    @Test func parsesBarePorcelainAndNulSeparated() {
        let bare = GitWorktrees.parsePorcelain("worktree /r.git\nbare\n")
        #expect(bare == [{ var e = GitWorktreeEntry(path: "/r.git"); e.isBare = true; return e }()])
        let z = GitWorktrees.parsePorcelain("worktree /a\0HEAD abc\0branch refs/heads/x\0\0worktree /b\0detached\0\0")
        #expect(z.map(\.path) == ["/a", "/b"])
        #expect(z[0].branch == "x" && z[1].isDetached)
        #expect(GitWorktrees.parsePorcelain("").isEmpty)
    }

    @Test func rejectsUnsafeAgentIds() throws {
        for bad in ["../evil", "a/b", "has space", "", "  ", "-x;rm", "ção"] {
            #expect(throws: GitWorktreeError.invalidAgentId) { try GitWorktrees.sanitizeAgentId(bad) }
        }
        #expect(try GitWorktrees.sanitizeAgentId(" agent-01_x ") == "agent-01_x")
        #expect(GitWorktrees.branchName(for: "a1") == "alethe/agent-a1")
    }

    @Test func pendingChangesSkipInfrastructure() {
        let output = "?? README.md\n M src/a.swift\n?? opencode.json\n?? .planning/goal.md\n?? .opencode/plugins/x.ts\n"
        #expect(GitWorktrees.parsePendingChanges(output) == [
            WorktreePendingChange(path: "README.md", status: "??"),
            WorktreePendingChange(path: "src/a.swift", status: "M"),
        ])
    }

    @Test func settingsModel() throws {
        let off = WorktreeSettings()
        #expect(off.effectiveMode == .gitWorktree)
        #expect(off.agentIdForNewTerminal(isAgent: true, terminalId: "t1") == nil)
        let on = WorktreeSettings(autoWorktree: true, worktreeMode: .localCopy)
        #expect(on.agentIdForNewTerminal(isAgent: true, terminalId: "t1") == "t1")
        #expect(on.agentIdForNewTerminal(isAgent: false, terminalId: "t1") == nil)
        #expect(on.agentIdForNewTerminal(isAgent: true, terminalId: "../x") == nil)
        let json = try JSONEncoder().encode(on)
        #expect(String(decoding: json, as: UTF8.self).contains("\"localCopy\""))
        #expect(try JSONDecoder().decode(WorktreeSettings.self, from: json) == on)
    }

    // MARK: G — temp repositories

    private let worktrees = GitWorktrees(runner: TempRepo.runner)

    @Test func provisionListAndRemoveBothModes() async throws {
        let repo = try await TempRepo()
        let wt = try await worktrees.provision(repo: repo.url, agentId: "wt1", mode: .gitWorktree)
        #expect(wt.branch == "alethe/agent-wt1")
        #expect(wt.path == repo.url.appendingPathComponent(".alethe/worktrees/wt1").path)
        #expect(GitWorktrees.detectMode(URL(fileURLWithPath: wt.path)) == .gitWorktree)
        let lc = try await worktrees.provision(repo: repo.url, agentId: "lc1", mode: .localCopy)
        #expect(GitWorktrees.detectMode(URL(fileURLWithPath: lc.path)) == .localCopy)

        // Resolves the main repository from inside a linked worktree too.
        let listed = try await worktrees.list(repo: URL(fileURLWithPath: wt.path))
        #expect(listed.map(\.agentId) == ["lc1", "wt1"])
        #expect(listed.map(\.branch) == ["alethe/agent-lc1", "alethe/agent-wt1"])
        #expect(listed.map(\.mode) == [.localCopy, .gitWorktree])

        let git = try await worktrees.gitWorktrees(repo: repo.url)
        #expect(git.compactMap(\.agentId) == ["wt1"])

        await #expect(throws: GitWorktreeError.exists) {
            try await worktrees.provision(repo: repo.url, agentId: "wt1", mode: .gitWorktree)
        }
        await #expect(throws: GitWorktreeError.invalidAgentId) {
            try await worktrees.provision(repo: repo.url, agentId: "../x", mode: .gitWorktree)
        }

        try await worktrees.remove(repo: repo.url, agentId: "wt1", force: false)
        try await worktrees.remove(repo: repo.url, agentId: "lc1", force: false)
        #expect(try await worktrees.list(repo: repo.url).isEmpty)
        await #expect(throws: GitWorktreeError.notFound) {
            try await worktrees.remove(repo: repo.url, agentId: "wt1", force: true)
        }
    }

    @Test func lockBlocksRemovalUntilUnlocked() async throws {
        let repo = try await TempRepo()
        _ = try await worktrees.provision(repo: repo.url, agentId: "a1", mode: .gitWorktree)
        try await worktrees.lock(repo: repo.url, agentId: "a1", reason: "Waiting for review")
        let entry = try await worktrees.gitWorktrees(repo: repo.url).first { $0.agentId == "a1" }
        #expect(entry?.isLocked == true && entry?.lockReason == "Waiting for review")
        await #expect(throws: GitWorktreeError.adminLocked(reason: "Waiting for review")) {
            try await worktrees.remove(repo: repo.url, agentId: "a1", force: true)
        }
        try await worktrees.unlock(repo: repo.url, agentId: "a1")
        try await worktrees.lock(repo: repo.url, agentId: "a1")
        await #expect(throws: GitWorktreeError.adminLocked(reason: "no reason given")) {
            try await worktrees.remove(repo: repo.url, agentId: "a1", force: true)
        }
        try await worktrees.unlock(repo: repo.url, agentId: "a1")
        try await worktrees.remove(repo: repo.url, agentId: "a1", force: true)
        #expect(try await worktrees.list(repo: repo.url).isEmpty)
    }

    @Test func commitPendingCommitsRealWorkOnly() async throws {
        let repo = try await TempRepo()
        let wt = try await worktrees.provision(repo: repo.url, agentId: "op1", mode: .gitWorktree)
        let dir = URL(fileURLWithPath: wt.path)
        #expect(try await worktrees.commitPending(repo: repo.url, agentId: "op1") == false)

        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".planning"), withIntermediateDirectories: true)
        try "goal\n".write(to: dir.appendingPathComponent(".planning/goal.md"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: dir.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        #expect(try await worktrees.pendingChanges(repo: repo.url, agentId: "op1").isEmpty)
        #expect(try await worktrees.commitPending(repo: repo.url, agentId: "op1") == false)

        try "agent work\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(try await worktrees.pendingChanges(repo: repo.url, agentId: "op1") == [
            WorktreePendingChange(path: "README.md", status: "M"),
        ])
        #expect(try await worktrees.commitPending(repo: repo.url, agentId: "op1", message: "real work"))
        let subject = try await TempRepo.runner.run(["log", "-1", "--format=%s"], in: dir).text
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "real work")
        let files = try await TempRepo.runner.run(["show", "--name-only", "--format=", "HEAD"], in: dir).text
        #expect(files.trimmingCharacters(in: .whitespacesAndNewlines) == "README.md")

        try "more\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        #expect(try await worktrees.commitPending(repo: repo.url, agentId: "op1", message: "   "))
        let fallback = try await TempRepo.runner.run(["log", "-1", "--format=%s"], in: dir).text
        #expect(fallback.trimmingCharacters(in: .whitespacesAndNewlines) == GitWorktrees.defaultCommitMessage)

        await #expect(throws: GitWorktreeError.notFound) {
            try await worktrees.commitPending(repo: repo.url, agentId: "nope")
        }
        try await worktrees.remove(repo: repo.url, agentId: "op1", force: true)
    }

    @Test func fetchBranchBringsLocalCopyWorkIntoMainRepo() async throws {
        let repo = try await TempRepo()
        let lc = try await worktrees.provision(repo: repo.url, agentId: "fetchme", mode: .localCopy)
        let dir = URL(fileURLWithPath: lc.path)
        for (key, value) in [("user.name", "Alethe Test"), ("user.email", "test@alethe.local"), ("commit.gpgsign", "false")] {
            _ = try await TempRepo.runner.run(["config", key, value], in: dir)
        }
        try "copy work\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(try await worktrees.commitPending(repo: repo.url, agentId: "fetchme"))
        let verify = ["rev-parse", "--verify", "-q", "refs/heads/alethe/agent-fetchme"]
        #expect(try await TempRepo.runner.run(verify, in: repo.url, allowedExitCodes: [0, 1]).exitCode == 1)
        try await worktrees.fetchBranch(repo: repo.url, agentId: "fetchme")
        #expect(try await TempRepo.runner.run(verify, in: repo.url).exitCode == 0)

        _ = try await worktrees.provision(repo: repo.url, agentId: "wtnoop", mode: .gitWorktree)
        try await worktrees.fetchBranch(repo: repo.url, agentId: "wtnoop")
        await #expect(throws: GitWorktreeError.notFound) {
            try await worktrees.fetchBranch(repo: repo.url, agentId: "nope")
        }
    }

    @Test func cleanupPrunesAndRemovesStaleDirectories() async throws {
        let repo = try await TempRepo()
        let wt = try await worktrees.provision(repo: repo.url, agentId: "gone", mode: .gitWorktree)
        _ = try await worktrees.provision(repo: repo.url, agentId: "kept", mode: .gitWorktree)
        // Simulate a crash: the worktree's `.git` pointer vanished, leaving a stale directory and metadata.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: wt.path).appendingPathComponent(".git"))
        #expect(try await worktrees.gitWorktrees(repo: repo.url).count == 3)

        let removed = try await worktrees.cleanup(repo: repo.url)
        #expect(removed == ["gone"])
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try await worktrees.list(repo: repo.url).map(\.agentId) == ["kept"])
        #expect(try await worktrees.gitWorktrees(repo: repo.url).compactMap(\.agentId) == ["kept"])
    }
}
