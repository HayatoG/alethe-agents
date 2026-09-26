import AletheGit
import Darwin
import Foundation
import Testing
@testable import AletheMerge

// Spawns real processes: a hang must fail the test, not stall the run.
@Suite(.timeLimit(.minutes(1))) struct BranchTestingTests {
    static let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])

    static func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Polls until `pid` is gone (a killed orphan is reaped by launchd shortly after).
    static func gone(_ pid: pid_t, within seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    static func readPID(_ url: URL) -> pid_t? {
        (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: G — health probe kills the whole tree

    @Test func healthProbeKillsChildrenInItsGroup() async throws {
        let dir = try Self.tempDir("alethe-probe-group")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A backgrounded child in the shell's group, plus one that leaves the group (setpgrp).
        let command = """
            sleep 300 & echo $! > child.pid
            perl -e 'setpgrp(0, 0); sleep 300' & echo $! > detached.pid
            sleep 300
            """
        let result = try await HealthProbe().run(in: dir, startCommand: command, path: "/", timeoutMs: 1500)
        #expect(result.started && !result.responded)
        let child = try #require(Self.readPID(dir.appendingPathComponent("child.pid")))
        let detached = try #require(Self.readPID(dir.appendingPathComponent("detached.pid")))
        #expect(await Self.gone(child))
        #expect(await Self.gone(detached))
    }

    @Test func groupProcessReportsExitAndKillIsSafeAfterwards() async throws {
        let dir = try Self.tempDir("alethe-group-exit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = try GroupProcess.spawn(shell: URL(fileURLWithPath: "/bin/sh"), command: "exit 3",
                                             directory: dir, environment: ProcessInfo.processInfo.environment)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(!process.isRunning)
        process.killTree()
        #expect(getpgid(process.pid) == -1)
    }

    @Test func groupProcessRunsInItsDirectoryAsGroupLeader() async throws {
        let dir = try Self.tempDir("alethe-group-cwd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = try GroupProcess.spawn(shell: URL(fileURLWithPath: "/bin/sh"), command: "pwd; sleep 300",
                                             directory: dir, environment: ProcessInfo.processInfo.environment)
        #expect(getpgid(process.pid) == process.pid)
        #expect(getpgid(process.pid) != getpgrp())
        // Read before killing: `pwd` must have run, or the kill can land before the shell prints.
        let printed = Self.read(process.output, within: 10)
        process.killTree()
        #expect(!process.isRunning)
        let output = String(decoding: printed, as: UTF8.self)
        // `pwd` prints the real path (`/private/var/…`); compare both sides resolved.
        let printedPath = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(printedPath.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path, "pwd printed \(output)")
    }

    /// Waits up to `seconds` for the first output instead of blocking a test thread forever.
    private static func read(_ handle: FileHandle, within seconds: Double) -> Data {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(seconds * 1000)) > 0 else { return Data() }
        return handle.availableData
    }

    @Test func descendantsWalkParentsBeforeChildren() {
        let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 10, 13: 11, 20: 1, 1: 1]
        #expect(GroupProcess.descendants(of: 10, parents: parents) == [10, 11, 12, 13])
        #expect(GroupProcess.descendants(of: 99, parents: parents) == [99])
    }

    // MARK: G — branch testing

    /// `main` checked out; `feature` adds a script the validation runs, and an API mismatch.
    static func repo() async throws -> URL {
        let root = try tempDir("alethe-branch-test")
        func git(_ args: String...) async throws { _ = try await runner.run(args, in: root) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git("init", "-b", "main")
        try await git("config", "user.name", "Alethe Test")
        try await git("config", "user.email", "alethe@example.invalid")
        try await git("config", "commit.gpgsign", "false")
        try write("server.js", "app.get('/api/v1/users', handler)\n")
        try await git("add", ".")
        try await git("commit", "-m", "base")
        try await git("checkout", "-b", "feature")
        try write("check.sh", "echo feature-check\n")
        try write("api.ts", "fetch('/api/v2/users')\n")
        try await git("add", ".")
        try await git("commit", "-m", "feature")
        try await git("checkout", "main")
        return root
    }

    @Test func testsABranchInATemporaryCheckoutAndCleansUp() async throws {
        let root = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let tester = BranchTester(root: root, runner: Self.runner)
        let result = try await tester.test(branch: "feature", settings: ValidationSettings(commands: ["sh check.sh"]))
        #expect(result.status == .passed)
        #expect(result.validation.steps.first?.output.contains("feature-check") == true)
        #expect(result.contractWarnings.map(\.call.pathPattern) == ["/api/v2/users"])
        #expect(result.hasWarnings)
        #expect(result.commit.count == 40)
        // The user's tree is untouched and the checkout is gone.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("check.sh").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: BranchTester.directory(root: root).path)) ?? []
        #expect(leftovers.isEmpty)
        let worktrees = try await Self.runner.run(["worktree", "list", "--porcelain"], in: root).text
        #expect(!worktrees.contains("branch-tests"))

        let failing = try await tester.test(branch: "main", settings: ValidationSettings(commands: ["sh check.sh"]))
        #expect(failing.status == .failed)
        await #expect(throws: MergeError.branchNotFound("nope")) {
            try await tester.test(branch: "nope", settings: ValidationSettings())
        }
    }

    @Test func logKeepsResultsPerBranchAndPersists() throws {
        let root = try Self.tempDir("alethe-branch-log")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = ValidationReport(status: .unverified, steps: [], healthProbe: nil, finishedAt: Date(timeIntervalSince1970: 0))
        var log = BranchTestLog()
        for index in 0..<(BranchTestLog.limit + 2) {
            log.record(BranchTestResult(branch: "a", commit: "\(index)", validation: report, healthProbe: nil,
                                        contractWarnings: [], finishedAt: Date(timeIntervalSince1970: 0)))
        }
        log.record(BranchTestResult(branch: "b", commit: "x", validation: report, healthProbe: nil,
                                    contractWarnings: [], finishedAt: Date(timeIntervalSince1970: 0)))
        #expect(log.history(for: "a").count == BranchTestLog.limit)
        #expect(log.latest(for: "a")?.commit == "\(BranchTestLog.limit + 1)")
        #expect(log.latest(for: "b")?.status == .unverified)
        try log.save(root: root)
        #expect(BranchTestLog.load(root: root) == log)
        log.forget(branch: "a")
        #expect(log.latest(for: "a") == nil)
        #expect(BranchTestLog.load(root: root.appendingPathComponent("missing")) == BranchTestLog())
    }
}
