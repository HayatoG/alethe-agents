import Foundation
import Testing
@testable import AletheGit

@Suite struct GitParsersTests {
    @Test func parsesBranchHeadersAndEveryEntryKind() {
        let fixture = [
            "# branch.oid 1234abcd",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 aaa bbb src/app.swift",
            "1 A. N... 000000 100644 100644 000 ccc new file.txt",
            "1 MM N... 100644 100644 100644 aaa bbb both.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 renamed.txt",
            "old.txt",
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt",
            "1 .M SC.U 160000 160000 160000 s1 s2 vendor/lib",
            "? untracked.md",
            "! ignored.log",
        ].joined(separator: "\0") + "\0"
        let status = GitParsers.parseStatus(fixture)
        #expect(status.branch == GitBranchStatus(head: "main", oid: "1234abcd", upstream: "origin/main", ahead: 2, behind: 3))
        #expect(status.entries.count == 8)
        #expect(status.entries[0].worktree == .modified && status.entries[0].index == nil)
        #expect(status.entries[1].path == "new file.txt" && status.entries[1].index == .added)
        #expect(status.entries[2].isStaged && status.entries[2].isUnstaged)
        #expect(status.entries[3].kind == .renamed && status.entries[3].path == "renamed.txt" && status.entries[3].originalPath == "old.txt")
        #expect(status.conflicts.map(\.path) == ["conflict.txt"])
        #expect(!status.entries[4].isStaged)
        #expect(status.entries[5].submodule == GitSubmoduleState(commitChanged: true, hasTrackedChanges: false, hasUntracked: true))
        #expect(status.untracked.map(\.path) == ["untracked.md"])
        #expect(status.entries[7].kind == .ignored)
        #expect(!status.isClean)
    }

    @Test func parsesInitialAndDetachedHeads() {
        let initial = GitParsers.parseStatus("# branch.oid (initial)\0# branch.head main\0")
        #expect(initial.branch.oid == nil && initial.branch.head == "main" && initial.isClean)
        let detached = GitParsers.parseStatus("# branch.oid abc\0# branch.head (detached)\0")
        #expect(detached.branch.isDetached)
    }

    @Test func parsesNameStatusWithRenames() {
        let changes = GitParsers.parseNameStatus("M\0a.txt\0R087\0old.txt\0new.txt\0D\0gone.txt\0A\0added.txt\0")
        #expect(changes == [
            GitFileChange(path: "a.txt", originalPath: nil, change: .modified),
            GitFileChange(path: "new.txt", originalPath: "old.txt", change: .renamed),
            GitFileChange(path: "gone.txt", originalPath: nil, change: .deleted),
            GitFileChange(path: "added.txt", originalPath: nil, change: .added),
        ])
    }

    @Test func parsesNumstatIncludingRenamesAndBinaries() {
        let stats = GitParsers.parseNumstat("3\t1\ta.txt\0-\t-\timage.png\0" + "0\t2\t\0old.txt\0new.txt\0")
        #expect(stats == [
            GitDiffStat(path: "a.txt", added: 3, deleted: 1),
            GitDiffStat(path: "image.png", added: nil, deleted: nil),
            GitDiffStat(path: "new.txt", originalPath: "old.txt", added: 0, deleted: 2),
        ])
        #expect(stats[1].isBinary)
    }

    @Test func parsesLogRecordsWithRefs() {
        let us = "\u{1F}", rs = "\u{1E}"
        let fixture = [
            ["c2", "c1 m1", "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0", "Ada", "ada@x.io", "1700000000", "Merge a|b"].joined(separator: us),
            "\n" + ["c1", "", "", "Bob", "bob@x.io", "1600000000", "First"].joined(separator: us),
        ].joined(separator: rs) + rs + "\n"
        let commits = GitParsers.parseLog(fixture)
        #expect(commits.count == 2)
        #expect(commits[0].isMerge && commits[0].parents == ["c1", "m1"])
        #expect(commits[0].refs == [
            GitRef(kind: .branch, name: "main", isCurrent: true),
            GitRef(kind: .remoteBranch, name: "origin/main"),
            GitRef(kind: .tag, name: "v1.0"),
        ])
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(commits[1].parents.isEmpty && commits[1].refs.isEmpty && commits[1].subject == "First")
    }

    @Test func parsesDetachedHeadDecoration() {
        #expect(GitParsers.parseRefs("HEAD, refs/heads/topic") == [GitRef(kind: .head, name: "HEAD"), GitRef(kind: .branch, name: "topic")])
    }

    @Test func parsesBranchesSkippingSymbolicRemoteHead() {
        let us = "\u{1F}"
        let fixture = [
            ["refs/heads/main", "aaa", "origin/main", "*"],
            ["refs/heads/topic", "bbb", "", " "],
            ["refs/remotes/origin/HEAD", "aaa", "", " "],
            ["refs/remotes/origin/main", "aaa", "", " "],
        ].map { $0.joined(separator: us) }.joined(separator: "\n") + "\n"
        let branches = GitParsers.parseBranches(fixture)
        #expect(branches == [
            GitBranch(name: "main", isRemote: false, isCurrent: true, oid: "aaa", upstream: "origin/main"),
            GitBranch(name: "topic", isRemote: false, isCurrent: false, oid: "bbb", upstream: nil),
            GitBranch(name: "origin/main", isRemote: true, isCurrent: false, oid: "aaa", upstream: nil),
        ])
    }

    @Test func rejectsUnsafeArguments() {
        #expect(throws: GitError.self) { try GitParsers.validateHash("--hard") }
        #expect(throws: GitError.self) { try GitParsers.validateHash("") }
        #expect(throws: GitError.self) { try GitParsers.validateBranchName("-D") }
        #expect(throws: GitError.self) { try GitParsers.validateBranchName("a b") }
        #expect(throws: GitError.self) { try GitParsers.validatePaths(["../outside"]) }
        #expect(throws: GitError.self) { try GitParsers.validatePaths(["/etc/passwd"]) }
        #expect(throws: GitError.self) { try GitParsers.validatePaths([]) }
        #expect(throws: Never.self) { try GitParsers.validatePaths(["src/a.swift", "dir with space/b"]) }
        #expect(throws: Never.self) { try GitParsers.validateHash("0123abcdef") }
    }

    @Test func watcherIgnoresObjectStoreAndLocks() {
        #expect(GitWatcher.isNoise("/r/.git/objects/ab/cdef"))
        #expect(GitWatcher.isNoise("/r/.git/index.lock"))
        #expect(!GitWatcher.isNoise("/r/.git/index"))
        #expect(!GitWatcher.isNoise("/r/src/a.swift"))
    }
}
