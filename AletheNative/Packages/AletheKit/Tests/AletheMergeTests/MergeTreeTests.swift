import AletheGit
import Foundation
import Testing
@testable import AletheMerge

/// Merge tree grouping (U) and resuming a prepared environment from its metadata (U + G).
struct MergeTreeTests {
    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    let conflicts = [
        ConflictFile(path: "src/app/main.ts"),
        ConflictFile(path: "Cargo.lock"),
        ConflictFile(path: "src/app/view.css"),
        ConflictFile(path: "src/lib.rs"),
        ConflictFile(path: "package.json"),
        ConflictFile(path: "src/app/main.ts"),
    ]

    // MARK: U — grouping

    @Test func groupsByFolderRootFirstAndDropsDuplicates() {
        let groups = MergeTree.groups(conflicts, by: .folder)
        #expect(groups.map(\.id) == ["", "src", "src/app"])
        #expect(groups.map(\.title) == [".", "src", "src/app"])
        #expect(groups[0].files.map(\.path) == ["Cargo.lock", "package.json"])
        #expect(groups[1].files.map(\.path) == ["src/lib.rs"])
        #expect(groups[2].files.map(\.path) == ["src/app/main.ts", "src/app/view.css"])
    }

    @Test func groupsByClassInVariantOrder() {
        let groups = MergeTree.groups(conflicts, by: .class)
        #expect(groups.map(\.title) == ["Cargo", "Package", "Rust", "TypeScript", "Ui"])
        #expect(groups.map(\.id) == ["cargo", "package", "rust", "typeScript", "ui"])
        #expect(groups.first { $0.id == "typeScript" }?.files.count == 1)
    }

    @Test func emptyAndPathHelpers() {
        #expect(MergeTree.groups([], by: .folder).isEmpty)
        #expect(MergeTree.folder(of: "a/b/c.txt") == "a/b")
        #expect(MergeTree.folder(of: "c.txt") == "")
        #expect(MergeTree.folder(of: "a\\b.txt") == "a")
        #expect(MergeTree.fileName(of: "a/b/c.txt") == "c.txt")
    }

    // MARK: U — resume point

    @Test func resumeStageFromMetadata() {
        // No record: conflicts decide.
        #expect(MergeResumePoint.stage(recorded: nil, conflictPaths: ["a.ts"]) == .prepare)
        #expect(MergeResumePoint.stage(recorded: nil, conflictPaths: []) == .validate)
        #expect(MergeResumePoint.stage(recorded: .analyze, conflictPaths: []) == .validate)
        // The recorded stage wins.
        #expect(MergeResumePoint.stage(recorded: .finish, conflictPaths: ["a.ts"]) == .finish)
        #expect(MergeResumePoint.stage(recorded: .validate, conflictPaths: ["a.ts"], unresolved: []) == .validate)
        // Unmerged files send it back to Prepare.
        #expect(MergeResumePoint.stage(recorded: .finish, conflictPaths: [], unresolved: ["a.ts"]) == .prepare)
    }

    @Test func metadataWithoutNativeFieldsStillDecodes() throws {
        let upstream = #"{"id":"abc","source":"feature","target":"main","projectId":null,"conflictPaths":["a.ts"]}"#
        let meta = try JSONDecoder().decode(MergeMeta.self, from: Data(upstream.utf8))
        #expect(meta.stage == nil && meta.lastValidation == nil && meta.contractWarnings == nil)
        #expect(MergeSessionSummary(meta: meta).stage == .prepare)
        #expect(MergeSessionSummary(meta: meta).conflicts == [ConflictFile(path: "a.ts")])
    }

    // MARK: G — scanning and resuming

    func repo() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-resume-\(UUID().uuidString)", isDirectory: true)
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
        try write("shared.ts", "base\n")
        try await git("add", ".")
        try await git("commit", "-m", "base")
        for branch in ["agent-a", "agent-b"] {
            try await git("checkout", "-b", branch, "main")
            try write("shared.ts", "\(branch)\n")
            try await git("commit", "-am", branch)
        }
        try await git("checkout", "main")
        return root
    }

    @Test func inProgressListsPreparedEnvironmentsAndResumes() async throws {
        let root = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ConflictResolution(root: root, runner: Self.runner)
        #expect(resolution.inProgress().isEmpty)

        let env = try await resolution.prepare(source: "agent-b", target: "agent-a")
        // Stray files are ignored: metadata without a worktree and non-JSON entries.
        let envs = MergeAnalyzer.mergeEnvsDirectory(root: root)
        try Data("{}".utf8).write(to: envs.appendingPathComponent("orphan.json"))
        try Data().write(to: envs.appendingPathComponent("notes.txt"))

        let sessions = resolution.inProgress()
        #expect(sessions.map(\.id) == [env.id])
        #expect(sessions.first?.stage == .prepare)
        #expect(sessions.first?.meta.source == "agent-b")

        try resolution.updateMeta(id: env.id) { $0.stage = .validate }
        #expect(resolution.inProgress().first?.stage == .validate)

        let resumed = try await resolution.resume(id: env.id)
        #expect(resumed.meta.target == "agent-a")
        #expect(resumed.environment.path.standardizedFileURL == env.path.standardizedFileURL)
        #expect(resumed.environment.conflicts.map(\.path) == ["shared.ts"])
        #expect(resumed.environment.promptPath != nil)
        #expect(!resumed.environment.clean)
        let stage = MergeResumePoint.stage(recorded: resumed.meta.stage, conflictPaths: resumed.meta.conflictPaths,
                                           unresolved: resumed.environment.conflicts.map(\.path))
        #expect(stage == .prepare)

        try await resolution.abort(id: env.id)
        #expect(resolution.inProgress().isEmpty)
        await #expect(throws: ConflictResolutionError.environmentNotFound(env.id)) {
            try await resolution.resume(id: env.id)
        }
    }
}
