import AletheGit
import Foundation
import Testing
@testable import AletheMerge

/// Port of upstream `detects_conflict_and_clean_merges` against a throwaway repository.
struct MergeAnalyzerTests {
    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    func conflictingRepo() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-merge-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: String...) async throws { _ = try await Self.runner.run(args, in: root) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git("init", "-b", "main")
        try await git("config", "user.name", "Alethe Test")
        try await git("config", "user.email", "alethe@example.invalid")
        try await git("config", "commit.gpgsign", "false")
        try write("shared.ts", "export const value = 'base'\n")
        try write("other.rs", "fn base() {}\n")
        try await git("add", ".")
        try await git("commit", "-m", "base")
        try await git("checkout", "-b", "agent-a")
        try write("shared.ts", "export const value = 'from-a'\n")
        try await git("commit", "-am", "a")
        try await git("checkout", "main")
        try await git("checkout", "-b", "agent-b")
        try write("shared.ts", "export const value = 'from-b'\n")
        try write("other.rs", "fn from_b() {}\n")
        try await git("commit", "-am", "b")
        try await git("checkout", "main")
        return root
    }

    @Test func detectsConflictAndCleanMerges() async throws {
        let root = try await conflictingRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let analyzer = MergeAnalyzer(root: root, runner: Self.runner)

        let clean = try await analyzer.analyze(source: "agent-a", target: "main")
        #expect(clean.clean)
        #expect(clean.conflicts.isEmpty)

        let conflicted = try await analyzer.analyze(source: "agent-b", target: "agent-a")
        #expect(!conflicted.clean)
        #expect(conflicted.conflicts == [ConflictFile(path: "shared.ts", class: .typeScript)])
        #expect(conflicted.classes == [.typeScript])

        // No trial worktree is left behind, and the user's checkout is untouched.
        let envs = MergeAnalyzer.mergeEnvsDirectory(root: root)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: envs.path)) ?? []
        #expect(leftovers.isEmpty)
        let worktrees = try await Self.runner.run(["worktree", "list", "--porcelain"], in: root).text
        #expect(worktrees.components(separatedBy: "worktree ").count == 2)
        let head = try await Self.runner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root).text
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        let status = try await Self.runner.run(["status", "--porcelain", "--untracked-files=no"], in: root).text
        #expect(status.isEmpty)

        await #expect(throws: MergeError.branchNotFound("nope")) {
            try await analyzer.analyze(source: "nope", target: "main")
        }
        await #expect(throws: MergeError.invalidBranch("--help")) {
            try await analyzer.analyze(source: "--help", target: "main")
        }
    }
}
