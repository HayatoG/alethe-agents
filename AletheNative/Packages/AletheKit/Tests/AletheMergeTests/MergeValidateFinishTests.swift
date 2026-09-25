import AletheGit
import Foundation
import Testing
@testable import AletheMerge

struct MergeValidateFinishTests {
    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    static func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func git(_ dir: URL, _ args: String...) async throws -> String {
        try await runner.run(args, in: dir).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `main` checked out, `feature` one commit ahead with a new file.
    static func repo() async throws -> URL {
        let root = try tempDir("alethe-finish")
        _ = try await git(root, "init", "-b", "main")
        _ = try await git(root, "config", "user.name", "Alethe Test")
        _ = try await git(root, "config", "user.email", "test@alethe.local")
        try "base\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, "add", "-A")
        _ = try await git(root, "commit", "-m", "base")
        _ = try await git(root, "checkout", "-b", "feature")
        try "feature\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, "add", "-A")
        _ = try await git(root, "commit", "-m", "feature")
        _ = try await git(root, "checkout", "main")
        return root
    }

    /// Mirrors upstream `merge_prepare` for a clean merge.
    static func prepare(_ root: URL) async throws -> MergeEnvHandle {
        let env = MergeEnvHandle(id: "t\(UUID().uuidString.prefix(8).lowercased())", source: "feature", target: "main")
        try FileManager.default.createDirectory(at: MergeAnalyzer.mergeEnvsDirectory(root: root), withIntermediateDirectories: true)
        _ = try await git(root, "worktree", "add", "-b", env.branch, env.directory(root: root).path, "main")
        _ = try await git(env.directory(root: root), "merge", "--no-commit", "--no-ff", "feature")
        return env
    }

    static func finisher(_ root: URL) -> MergeFinisher { MergeFinisher(root: root, runner: runner) }

    // MARK: G — validation runner

    @Test func validationRunnerPassesAndCapturesOutput() async throws {
        let dir = try Self.tempDir("alethe-validate")
        let report = await ValidationRunner().run(["echo hello", "  ", "echo err 1>&2"], in: dir)
        #expect(report.status == .passed)
        #expect(report.steps.count == 2)
        #expect(report.steps[0].output.contains("hello"))
        #expect(report.steps[1].output.contains("err"))
    }

    @Test func validationRunnerStopsAtFirstFailure() async throws {
        let dir = try Self.tempDir("alethe-validate")
        let report = await ValidationRunner().run(["echo out; exit 3", "echo never"], in: dir)
        #expect(report.status == .failed)
        #expect(report.steps.count == 1)
        #expect(report.steps[0].exitCode == 3)
        #expect(report.failedCommand == "echo out; exit 3")
    }

    @Test func validationRunnerWithoutCommandsIsUnverified() async throws {
        let report = await ValidationRunner().run([" "], in: try Self.tempDir("alethe-validate"))
        #expect(report.status == .unverified)
        #expect(!report.ranAnyCommand)
    }

    @Test func validationRunnerCancels() async throws {
        let dir = try Self.tempDir("alethe-validate")
        let start = Date()
        let task = Task { await ValidationRunner().run(["sleep 30", "echo never"], in: dir) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let report = await task.value
        #expect(report.status == .cancelled)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func validationLogKeepsResultsPerMergeAndRoundTrips() throws {
        var log = MergeValidationLog()
        let report = ValidationReport(status: .passed, steps: [ValidationStepResult(command: "true", exitCode: 0, output: "", durationMs: 1)],
                                      healthProbe: nil, finishedAt: Date(timeIntervalSince1970: 0))
        log.record(report, forMerge: "m1")
        let decoded = try JSONDecoder().decode(MergeValidationLog.self, from: JSONEncoder().encode(log))
        #expect(decoded.latest(forMerge: "m1") == report)
        #expect(decoded.latest(forMerge: "m2") == nil)
    }

    @Test func suggestedCommandsFromManifests() throws {
        let dir = try Self.tempDir("alethe-suggest")
        try #"{"scripts":{"build":"vite build","test":"vitest"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        #expect(ValidationSettings.suggested(for: dir).commands == ["npm run build", "npm test", "cargo build", "cargo test"])
    }

    @Test func suggestedCommandsAddTheDetectedStacksChecks() throws {
        let dir = try Self.tempDir("alethe-suggest-stack")
        try #"{"scripts":{"build":"vite build"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src-tauri"), withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("src-tauri/tauri.conf.json"), atomically: true, encoding: .utf8)
        #expect(ValidationSettings.suggested(for: dir).commands == ["npm run build", "cargo check --manifest-path src-tauri/Cargo.toml"])
    }

    // MARK: G — finish

    @Test func finalizeCleanBranchFastForwardsAndTearsDown() async throws {
        let root = try await Self.repo()
        let env = try await Self.prepare(root)
        let outcome = try await Self.finisher(root).finalize(env, settings: ValidationSettings(commands: ["test -f b.txt"]))
        #expect(outcome.merged)
        #expect(outcome.stage == .merged)
        #expect(outcome.validationRan)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: env.directory(root: root).path))
        let branches = try await Self.git(root, "branch", "--list", env.branch)
        #expect(branches.isEmpty)
    }

    @Test func finalizeBlockedByFailingValidationPreservesEnvironment() async throws {
        let root = try await Self.repo()
        let env = try await Self.prepare(root)
        let outcome = try await Self.finisher(root).finalize(env, settings: ValidationSettings(commands: ["exit 1"]))
        #expect(!outcome.merged)
        #expect(outcome.stage == .validation)
        #expect(FileManager.default.fileExists(atPath: env.directory(root: root).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    @Test func finalizeRequiresTargetCheckedOut() async throws {
        let root = try await Self.repo()
        let env = try await Self.prepare(root)
        _ = try await Self.git(root, "checkout", "feature")
        let outcome = try await Self.finisher(root).finalize(env)
        #expect(outcome.stage == .targetNotCheckedOut)
    }

    @Test func abortRestoresRepository() async throws {
        let root = try await Self.repo()
        let before = try await Self.git(root, "rev-parse", "main")
        let env = try await Self.prepare(root)
        let finisher = Self.finisher(root)
        try await finisher.preflightAbort(env)
        try await finisher.preflightAbort(env) // nothing in progress: still a no-op
        try await finisher.abort(env)
        #expect(!FileManager.default.fileExists(atPath: env.directory(root: root).path))
        #expect(try await Self.git(root, "rev-parse", "main") == before)
        #expect(try await Self.git(root, "branch", "--list", env.branch).isEmpty)
        #expect(try await Self.git(root, "status", "--porcelain").isEmpty)
    }

    @Test func forceCleanupRemovesEnvironmentAndIsIdempotent() async throws {
        let root = try await Self.repo()
        let env = try await Self.prepare(root)
        let finisher = Self.finisher(root)
        let first = try await finisher.forceCleanup(env)
        #expect(first == MergeForceCleanupResult(deleted: true, pruned: true))
        #expect(!FileManager.default.fileExists(atPath: env.directory(root: root).path))
        let list = try await Self.git(root, "worktree", "list")
        #expect(!list.contains(env.id))
        #expect(try await finisher.forceCleanup(env).deleted)
        await #expect(throws: MergeFinishError.invalidEnvironmentID("../x")) {
            try await finisher.forceCleanup(MergeEnvHandle(id: "../x", source: "a", target: "b"))
        }
    }

    @Test func commitPendingThenRemoveWorktree() async throws {
        let root = try await Self.repo()
        let worktree = root.appendingPathComponent(".alethe/worktrees/agent1", isDirectory: true)
        _ = try await Self.git(root, "worktree", "add", "-b", "agent1", worktree.path, "main")
        try "work\n".write(to: worktree.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".planning"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent(".planning/p.md"), atomically: true, encoding: .utf8)
        let finisher = Self.finisher(root)
        #expect(try await finisher.pendingChanges(in: worktree).map(\.path) == ["c.txt"])
        #expect(try await finisher.commitPending(in: worktree, message: "agent work"))
        #expect(try await Self.git(worktree, "log", "-1", "--format=%s") == "agent work")
        try await finisher.removeWorktree(at: worktree, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        await #expect(throws: MergeFinishError.invalidPath) {
            try await finisher.removeWorktree(at: root.appendingPathComponent("elsewhere"))
        }
    }

    // MARK: U — health probe parsing

    @Test func healthProbeURLNormalizesPath() {
        #expect(HealthProbe.probeURL(port: 4000, path: nil)?.absoluteString == "http://127.0.0.1:4000/")
        #expect(HealthProbe.probeURL(port: 4000, path: " ")?.absoluteString == "http://127.0.0.1:4000/")
        #expect(HealthProbe.probeURL(port: 4000, path: "api/health")?.absoluteString == "http://127.0.0.1:4000/api/health")
        #expect(HealthProbe.probeURL(port: 4000, path: "/x")?.absoluteString == "http://127.0.0.1:4000/x")
    }

    @Test func healthProbeCapsOutputTailOnCharacterBoundary() {
        #expect(HealthProbe.capped("abcdef", limit: 3) == "def")
        #expect(HealthProbe.capped("abc", limit: 10) == "abc")
        #expect(HealthProbe.capped("aé", limit: 1) == "")
        #expect(HealthProbe.capped("aéb", limit: 3) == "éb")
    }

    @Test func healthProbeRecognizesAletheCoreAndHealth() {
        #expect(HealthProbe.isAletheCore(healthBody: Data(#"{"service":"alethe-core","ok":true}"#.utf8)))
        #expect(!HealthProbe.isAletheCore(healthBody: Data(#"{"service":"other"}"#.utf8)))
        #expect(!HealthProbe.isAletheCore(healthBody: Data("not json".utf8)))
        #expect(HealthProbe.effectiveTimeout(ms: 10) == 1000)
        #expect(HealthProbeResult(started: true, responded: true, statusCode: 204, elapsedMs: 1, outputTail: "").healthy)
        #expect(!HealthProbeResult(started: true, responded: true, statusCode: 500, elapsedMs: 1, outputTail: "").healthy)
        #expect(!HealthProbeResult(started: true, responded: false, statusCode: nil, elapsedMs: 1, outputTail: "").healthy)
    }

    @Test func healthProbeReportsNoResponseWhenCommandExits() async throws {
        let result = try await HealthProbe().run(in: try Self.tempDir("alethe-probe"), startCommand: "echo booting; exit 0", path: "/", timeoutMs: 2000)
        #expect(result.started)
        #expect(!result.responded)
        #expect(result.outputTail.contains("booting"))
        await #expect(throws: HealthProbeError.environmentNotFound) {
            try await HealthProbe().run(in: URL(fileURLWithPath: "/nonexistent-\(UUID())"), startCommand: "true", path: nil)
        }
    }
}
