import Foundation
import Testing
@testable import AletheGit

/// A throwaway repository isolated from the user's git configuration.
struct TempRepo {
    static let runner = GitRunner(environment: [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ])

    let url: URL
    let repo: GitRepository

    init(bare: Bool = false, empty: Bool = false) async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-git-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        repo = GitRepository(root: url, runner: Self.runner)
        if bare {
            try await git("init", "--bare", "-b", "main")
            return
        }
        try await git("init", "-b", "main")
        try await git("config", "user.name", "Alethe Test")
        try await git("config", "user.email", "test@alethe.local")
        try await git("config", "commit.gpgsign", "false")
        if !empty {
            try write("README.md", "hello\n")
            try await git("add", "-A")
            try await git("commit", "-m", "initial")
        }
    }

    @discardableResult
    func git(_ args: String...) async throws -> String {
        try await Self.runner.run(args, in: url).text
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func commitFile(_ path: String, _ contents: String, _ message: String) async throws {
        try write(path, contents)
        try await git("add", "--", path)
        try await git("commit", "-m", message)
    }

    func head() async throws -> String {
        try await git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct GitRepositoryTests {
    @Test func discoversTheTopLevelFromASubdirectory() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try t.write("src/deep/file.txt", "x")
        let root = try await GitRepository.discover(t.url.appendingPathComponent("src/deep"), runner: TempRepo.runner)
        #expect(root.path == t.url.path)
        let fromFile = try await GitRepository.discover(t.url.appendingPathComponent("src/deep/file.txt"), runner: TempRepo.runner)
        #expect(fromFile.path == t.url.path)
    }

    @Test func notARepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethe-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = GitRunner(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CEILING_DIRECTORIES": dir.deletingLastPathComponent().path])
        await #expect(throws: GitError.notARepository) {
            _ = try await GitRepository.discover(dir, runner: runner)
        }
        await #expect(throws: GitError.notARepository) {
            _ = try await GitRepository.discover(dir.appendingPathComponent("missing"), runner: runner)
        }
        await #expect(throws: GitError.notARepository) {
            _ = try await GitRepository(root: dir, runner: runner).status()
        }
    }

    @Test func gitMissing() async {
        let runner = GitRunner(executable: nil)
        await #expect(throws: GitError.gitMissing) {
            _ = try await runner.run(["--version"], in: FileManager.default.temporaryDirectory)
        }
    }

    @Test func initAdoptsExistingFilesAndIsIdempotent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-init-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "code".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "dep".write(to: dir.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)

        let root = try await GitRepository.initialize(dir, runner: TempRepo.runner)
        #expect(root.path == dir.path)
        let repo = GitRepository(root: root, runner: TempRepo.runner)
        let tracked = try await repo.run(["ls-tree", "-r", "--name-only", "HEAD"]).text
        #expect(tracked.contains("main.swift") && tracked.contains(".gitignore") && !tracked.contains("node_modules"))
        _ = try await GitRepository.initialize(dir, runner: TempRepo.runner)
        #expect(try await repo.log().count == 1)
    }

    @Test func statusCoversModifiedUntrackedStagedAndRenamed() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try await t.commitFile("move-me.txt", "some long enough content\nfor rename detection\n", "add file")
        try t.write("README.md", "changed\n")
        try t.write("new.txt", "untracked")
        try t.write("staged.txt", "staged")
        try await t.git("add", "staged.txt")
        try await t.git("mv", "move-me.txt", "moved.txt")

        let status = try await t.repo.status()
        #expect(status.branch.head == "main" && status.branch.oid != nil)
        #expect(status.unstaged.map(\.path) == ["README.md"])
        #expect(status.untracked.map(\.path) == ["new.txt"])
        let rename = try #require(status.entries.first { $0.kind == .renamed })
        #expect(rename.path == "moved.txt" && rename.originalPath == "move-me.txt" && rename.index == .renamed)
        #expect(Set(status.staged.map(\.path)) == ["staged.txt", "moved.txt"])
    }

    @Test func statusReportsMergeConflicts() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try await t.git("switch", "-c", "other")
        try await t.commitFile("README.md", "theirs\n", "theirs")
        try await t.git("switch", "main")
        try await t.commitFile("README.md", "ours\n", "ours")
        await #expect(throws: GitError.self) { try await t.git("merge", "other") }
        let status = try await t.repo.status()
        #expect(status.conflicts.map(\.path) == ["README.md"])
        #expect(status.conflicts.first?.index == .unmerged)
    }

    @Test func stageUnstageCommitAndAmend() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try t.write("a.txt", "a")
        try await t.repo.stage(["a.txt"])
        #expect(try await t.repo.status().staged.map(\.path) == ["a.txt"])
        try await t.repo.unstage(["a.txt"])
        #expect(try await t.repo.status().staged.isEmpty)
        #expect(try await t.repo.status().untracked.map(\.path) == ["a.txt"])

        try await t.repo.stageAll()
        let first = try await t.repo.commit(message: "add a")
        #expect(first == (try await t.head()))
        #expect(try await t.repo.status().isClean)

        try t.write("b.txt", "b")
        try await t.repo.stage(["b.txt"])
        let amended = try await t.repo.commit(message: "add a and b", amend: true)
        #expect(amended != first)
        let log = try await t.repo.log()
        #expect(log.count == 2 && log[0].subject == "add a and b")
        #expect(Set(try await t.repo.commitFiles(amended).map(\.path)) == ["a.txt", "b.txt"])

        try t.write("c.txt", "c")
        try await t.repo.stage(["c.txt"])
        try await t.repo.commit(message: nil, amend: true)
        #expect(try await t.repo.commitMessage(try await t.head()) == "add a and b")
        await #expect(throws: GitError.invalidArgument("empty commit message")) {
            try await t.repo.commit(message: "  ")
        }
    }

    @Test func unstageBeforeTheFirstCommit() async throws {
        let t = try await TempRepo(empty: true)
        defer { t.remove() }
        try t.write("a.txt", "a")
        try await t.repo.stage(["a.txt"])
        try await t.repo.unstage(["a.txt"])
        let status = try await t.repo.status()
        #expect(status.branch.oid == nil && status.untracked.map(\.path) == ["a.txt"])
        #expect(try await t.repo.log().isEmpty)
    }

    @Test func discardRestoresTrackedAndDeletesUntracked() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try t.write("README.md", "scribbles\n")
        try t.write("junk.txt", "junk")
        try await t.repo.discard(["README.md"])
        try await t.repo.discard(["junk.txt"], untracked: true)
        #expect(try t.read("README.md") == "hello\n")
        #expect(!t.exists("junk.txt"))
        await #expect(throws: GitError.self) { try await t.repo.discard(["../escape"]) }
    }

    @Test func diffAndDiffSummary() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try t.write("README.md", "hello\nworld\n")
        let diff = try await t.repo.diff(path: "README.md")
        #expect(diff.contains("+world"))
        #expect(try await t.repo.diffSummary() == [GitDiffStat(path: "README.md", added: 1, deleted: 0)])
        #expect(try await t.repo.diff(staged: true).isEmpty)
        try await t.repo.stage(["README.md"])
        #expect(try await t.repo.diff(path: "README.md", staged: true).contains("+world"))
        #expect(try await t.repo.diffSummary(staged: true).count == 1)
        try t.write("fresh.txt", "brand new\n")
        #expect(try await t.repo.diffUntracked(path: "fresh.txt").contains("+brand new"))

        let base = try await t.head()
        try await t.repo.commit(message: "world")
        #expect(try await t.repo.diffSummary(range: "\(base)..HEAD").map(\.path) == ["README.md"])
    }

    @Test func branchesListCreateAndSwitch() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        try await t.repo.createBranch("feature/x")
        #expect(try await t.repo.currentBranch() == "feature/x")
        try await t.repo.createBranch("later", switchTo: false)
        try await t.repo.switchBranch("main")
        #expect(try await t.repo.currentBranch() == "main")
        let branches = try await t.repo.branches()
        #expect(branches.map(\.name) == ["feature/x", "later", "main"])
        #expect(branches.first { $0.isCurrent }?.name == "main")
        await #expect(throws: GitError.invalidArgument("branch name")) { try await t.repo.switchBranch("--orphan") }
        await #expect(throws: GitError.self) { try await t.repo.switchBranch("does-not-exist") }

        try await t.git("checkout", "--detach")
        #expect(try await t.repo.currentBranch() == nil)
        #expect(try await t.repo.status().branch.isDetached)
    }

    @Test func logIsPaginatedAndDecorated() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        for i in 1...4 { try await t.commitFile("f\(i).txt", "\(i)", "commit \(i)") }
        try await t.git("tag", "v1")
        let all = try await t.repo.log()
        #expect(all.map(\.subject) == ["commit 4", "commit 3", "commit 2", "commit 1", "initial"])
        #expect(all[0].refs.contains(GitRef(kind: .branch, name: "main", isCurrent: true)))
        #expect(all[0].refs.contains(GitRef(kind: .tag, name: "v1")))
        #expect(all[0].parents == [all[1].hash] && all[4].parents.isEmpty)
        #expect(all[0].authorName == "Alethe Test" && all[0].authorEmail == "test@alethe.local")
        let page = try await t.repo.log(skip: 2, limit: 2)
        #expect(page.map(\.subject) == ["commit 2", "commit 1"])
        #expect(try await t.repo.commitFiles(all[4].hash).map(\.path) == ["README.md"])
    }

    @Test func cherryPickRevertResetAndBranchFromCommit() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        let base = try await t.head()
        try await t.git("switch", "-c", "topic")
        try await t.commitFile("topic.txt", "topic", "topic work")
        let topic = try await t.head()
        try await t.git("switch", "main")

        try await t.repo.cherryPick(topic)
        #expect(try t.read("topic.txt") == "topic")
        #expect(try await t.repo.log(allRefs: false).first?.subject == "topic work")

        try await t.repo.revert(try await t.head())
        #expect(!t.exists("topic.txt"))
        #expect(try await t.repo.log(allRefs: false).first?.subject.hasPrefix("Revert") == true)

        try await t.repo.reset(to: base, mode: .soft)
        #expect(try await t.head() == base)
        #expect(try await t.repo.status().isClean) // cherry-pick + revert cancel out
        try await t.commitFile("x.txt", "x", "x")
        try await t.repo.reset(to: base, mode: .mixed)
        #expect(try await t.repo.status().untracked.map(\.path) == ["x.txt"])
        try await t.repo.stage(["x.txt"])
        try await t.repo.commit(message: "x again")
        try await t.repo.reset(to: base, mode: .hard)
        #expect(!t.exists("x.txt"))

        try await t.repo.createBranch("from-topic", atCommit: topic)
        #expect(try await t.repo.currentBranch() == "main")
        #expect(try await t.git("rev-parse", "from-topic").hasPrefix(topic))
        await #expect(throws: GitError.invalidArgument("commit hash")) { try await t.repo.reset(to: "HEAD~1", mode: .hard) }
    }

    @Test func incomingOutgoingFetchPullPushWithALocalBareRemote() async throws {
        let remote = try await TempRepo(bare: true)
        defer { remote.remove() }
        let a = try await TempRepo()
        defer { a.remove() }
        #expect(try await a.repo.incomingOutgoing() == nil)
        try await a.git("remote", "add", "origin", remote.url.path)
        let lines = LineCollector()
        _ = try await a.repo.push(onProgress: { lines.append($0) }) // publishes with --set-upstream
        #expect(try await a.repo.status().branch.upstream == "origin/main")

        let b = try await TempRepo(empty: true)
        defer { b.remove() }
        try await b.git("remote", "add", "origin", remote.url.path)
        try await b.git("fetch", "origin")
        try await b.git("switch", "main")

        try await a.commitFile("a1.txt", "1", "a1")
        try await a.commitFile("a2.txt", "2", "a2")
        let outgoing = try #require(try await a.repo.incomingOutgoing())
        #expect(outgoing.upstream == "origin/main")
        #expect(outgoing.outgoing.map(\.subject) == ["a2", "a1"] && outgoing.incoming.isEmpty)
        #expect(try await a.repo.status().branch.ahead == 2)
        _ = try await a.repo.push()

        _ = try await b.repo.fetch(onProgress: { lines.append($0) })
        let incoming = try #require(try await b.repo.incomingOutgoing())
        #expect(incoming.incoming.map(\.subject) == ["a2", "a1"] && incoming.outgoing.isEmpty)
        #expect(try await b.repo.status().branch.behind == 2)
        _ = try await b.repo.pull()
        #expect(try b.read("a2.txt") == "2")
        #expect(try await b.repo.incomingOutgoing()?.incoming.isEmpty == true)
        #expect(try await b.repo.branches().contains { $0.isRemote && $0.name == "origin/main" })
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        let started = Date()
        let task = Task {
            try await t.repo.run(["-c", "alias.slow=!sleep 30", "slow"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: GitError.cancelled) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
        // The queue keeps working after a cancelled operation.
        #expect(try await t.repo.status().isClean)
    }

    @Test func operationsRunOneAtATimeInCallOrder() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        let repo = t.repo
        let slow = Task { try await repo.run(["-c", "alias.w=!sleep 0.4; echo first >> order.txt", "w"]) }
        try await Task.sleep(for: .milliseconds(100))
        let fast = Task { try await repo.run(["-c", "alias.w=!echo second >> order.txt", "w"]) }
        _ = try await slow.value
        _ = try await fast.value
        #expect(try t.read("order.txt") == "first\nsecond\n")
        let repositories = GitRepositories()
        #expect(repositories.repository(at: t.url) === repositories.repository(at: t.url))
    }

    @Test func watcherSignalsAfterAChange() async throws {
        let t = try await TempRepo()
        defer { t.remove() }
        let watcher = GitWatcher(root: t.url, debounce: .milliseconds(100))
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try t.write("touched.txt", "x")
        let signalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in watcher.events { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(signalled)
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
