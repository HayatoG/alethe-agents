import Foundation
import Testing
@testable import AletheGit

/// Returns canned outputs keyed by the first two arguments and records every call.
private final class FakeGh: GitHubCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: GitOutput]
    private(set) var calls: [[String]] = []

    init(_ responses: [String: GitOutput]) { self.responses = responses }

    func run(_ arguments: [String]) async throws -> GitOutput {
        let key = arguments.prefix(2).joined(separator: " ")
        let output = lock.withLock {
            calls.append(arguments)
            return responses[key]
        }
        guard let output else { throw GitHubPullRequestError.commandFailed(exitCode: 127, stderr: key) }
        return output
    }
}

private func output(_ exitCode: Int32, stdout: String = "", stderr: String = "") -> GitOutput {
    GitOutput(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

private let ghURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")

private let searchFixture = """
[
  {"number": 42, "title": "Add PR sidebar", "url": "https://github.com/kc1t/alethe/pull/42",
   "repository": {"name": "alethe", "nameWithOwner": "kc1t/alethe"},
   "author": {"login": "octo"}, "isDraft": false, "updatedAt": "2026-09-20T12:30:00Z"},
  {"number": 7, "title": "WIP: themes", "url": "https://github.com/kc1t/themes/pull/7",
   "repository": {"nameWithOwner": "kc1t/themes"},
   "author": {"login": "dev"}, "isDraft": true, "updatedAt": "2026-09-21T08:00:00.123Z"},
  {"number": 9, "repository": {"nameWithOwner": "kc1t/min"}},
  {"title": "no number", "repository": {"nameWithOwner": "kc1t/x"}}
]
"""

@Suite struct GitHubPullRequestTests {
    @Test func parsesOpenDraftAndMissingFields() throws {
        let prs = try GitHubPullRequestParser.parseSearch(Data(searchFixture.utf8))
        #expect(prs.count == 3)

        let open = prs[0]
        #expect(open.number == 42 && open.repo == "kc1t/alethe" && open.author == "octo")
        #expect(open.title == "Add PR sidebar" && !open.isDraft)
        #expect(open.updatedAt == ISO8601DateFormatter().date(from: "2026-09-20T12:30:00Z"))
        #expect(open.browserURL?.absoluteString == "https://github.com/kc1t/alethe/pull/42")
        #expect(open.checks == .none && open.reviewDecision == nil && open.headSHA == nil)

        #expect(prs[1].isDraft && prs[1].updatedAt != nil)

        let minimal = prs[2]
        #expect(minimal.title == "" && minimal.author == "" && minimal.url == nil && minimal.updatedAt == nil)
        #expect(minimal.browserURL?.absoluteString == "https://github.com/kc1t/min/pull/9")
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestParser.parseSearch(Data("{".utf8)) }
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestParser.parseSearch(Data("{}".utf8)) }
    }

    @Test func parsesDetailsWithFailingChecks() throws {
        let json = """
        {"headRefOid": "abc1234def", "reviewDecision": "CHANGES_REQUESTED", "isDraft": false,
         "statusCheckRollup": [
           {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
           {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""},
           {"__typename": "StatusContext", "state": "FAILURE"}
         ]}
        """
        let details = try GitHubPullRequestParser.parseDetails(Data(json.utf8))
        #expect(details.headSHA == "abc1234def")
        #expect(details.reviewDecision == .changesRequested)
        #expect(details.checks == .failure)

        let pr = PullRequestSummary(number: 1, title: "t", repo: "a/b", url: nil, author: "x", isDraft: true, updatedAt: nil)
        let merged = pr.merging(details)
        #expect(merged.headSHA == "abc1234def" && merged.checks == .failure && !merged.isDraft)
    }

    @Test func rollsUpChecks() {
        #expect(GitHubPullRequestParser.checksState(nil) == .none)
        #expect(GitHubPullRequestParser.checksState([[String: Any]]()) == .none)
        #expect(GitHubPullRequestParser.checksState([["conclusion": "SUCCESS"], ["state": "SUCCESS"], ["conclusion": "SKIPPED"]]) == .success)
        #expect(GitHubPullRequestParser.checksState([["conclusion": "SUCCESS"], ["status": "QUEUED", "conclusion": ""]]) == .pending)
        #expect(GitHubPullRequestParser.checksState([["state": "PENDING"], ["conclusion": "TIMED_OUT"]]) == .failure)
    }

    @Test func detectsMissingGh() async throws {
        let client = GitHubPullRequests(runner: FakeGh([:]), executable: nil)
        #expect(try await client.status() == .missing)
        await #expect(throws: GitHubPullRequestError.ghMissing) { try await client.listMine() }
    }

    @Test func detectsSignedOut() async throws {
        let fake = FakeGh(["auth status": output(1, stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login")])
        let client = GitHubPullRequests(runner: fake, executable: ghURL)
        #expect(try await client.status() == .signedOut)
        #expect(fake.calls == [["auth", "status"]])
    }

    @Test func reportsReadyWhenSignedIn() async throws {
        let fake = FakeGh(["auth status": output(0, stdout: "github.com\n  ✓ Logged in to github.com account octo (keyring)")])
        let client = GitHubPullRequests(runner: fake, executable: ghURL)
        #expect(try await client.status() == .ready(executable: ghURL))
    }

    @Test func listsWithUpstreamSearchArguments() async throws {
        let fake = FakeGh(["search prs": output(0, stdout: searchFixture)])
        let client = GitHubPullRequests(runner: fake, executable: ghURL)
        let prs = try await client.listMine()
        #expect(prs.count == 3)
        #expect(fake.calls == [[
            "search", "prs", "--involves=@me", "--state", "open",
            "--json", "number,title,url,repository,author,isDraft,updatedAt",
        ]])
    }

    @Test func listMapsAuthFailureToSignedOut() async {
        let fake = FakeGh(["search prs": output(4, stderr: "To get started with GitHub CLI, please run:  gh auth login")])
        let client = GitHubPullRequests(runner: fake, executable: ghURL)
        await #expect(throws: GitHubPullRequestError.signedOut) { try await client.listMine() }
    }

    @Test func buildsGuardedSquashMergeArguments() throws {
        let pr = PullRequestSummary(number: 42, title: "t", repo: "kc1t/alethe", url: nil, author: "x", isDraft: false, updatedAt: nil)
        let sha = "0123456789abcdef0123456789abcdef01234567"
        #expect(try GitHubPullRequestCommands.squashMergeArguments(pr: pr, headSHA: sha) == [
            "pr", "merge", "42", "--squash", "--match-head-commit", sha, "-R", "kc1t/alethe",
        ])
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestCommands.squashMergeArguments(pr: pr, headSHA: "") }
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestCommands.squashMergeArguments(pr: pr, headSHA: "--admin") }
        var bad = pr
        bad.repo = "-R/evil"
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestCommands.squashMergeArguments(pr: bad, headSHA: sha) }
        bad.repo = "noslash"
        #expect(throws: GitHubPullRequestError.self) { try GitHubPullRequestCommands.squashMergeArguments(pr: bad, headSHA: sha) }
    }

    @Test func locatesGhOnPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        FileManager.default.createFile(atPath: gh.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(GitHubCLIRunner.locateGh(path: dir.path)?.path == gh.path)
    }
}
