import Foundation

// MARK: - Model

/// Aggregated state of a PR's status checks (`statusCheckRollup`).
public enum PullRequestChecksState: String, Sendable, Equatable {
    case success, failure, pending, none
}

/// GitHub's review decision; `nil` on the model when the repo has no review requirement.
public enum PullRequestReviewDecision: String, Sendable, Equatable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// One open PR the signed-in user is involved in. `gh search prs` returns the list fields; review
/// decision, checks and head SHA come from `gh pr view` (search cannot return them) and stay unset
/// until the details are merged in.
public struct PullRequestSummary: Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String
    /// `owner/name`.
    public var repo: String
    public var url: URL?
    public var author: String
    public var isDraft: Bool
    public var updatedAt: Date?
    public var reviewDecision: PullRequestReviewDecision?
    public var checks: PullRequestChecksState
    public var headSHA: String?

    public var id: String { "\(repo)#\(number)" }

    public init(
        number: Int, title: String, repo: String, url: URL?, author: String, isDraft: Bool,
        updatedAt: Date?, reviewDecision: PullRequestReviewDecision? = nil,
        checks: PullRequestChecksState = .none, headSHA: String? = nil
    ) {
        self.number = number
        self.title = title
        self.repo = repo
        self.url = url
        self.author = author
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.headSHA = headSHA
    }

    /// The URL to open in the browser; falls back to the canonical github.com path.
    public var browserURL: URL? {
        if let url, url.scheme == "https" { return url }
        return URL(string: "https://github.com/\(repo)/pull/\(number)")
    }

    /// Merges the fields `gh pr view` returns.
    public func merging(_ details: PullRequestDetails) -> PullRequestSummary {
        var copy = self
        copy.reviewDecision = details.reviewDecision
        copy.checks = details.checks
        copy.headSHA = details.headSHA ?? headSHA
        if let isDraft = details.isDraft { copy.isDraft = isDraft }
        return copy
    }
}

public struct PullRequestDetails: Sendable, Equatable {
    public var headSHA: String?
    public var reviewDecision: PullRequestReviewDecision?
    public var checks: PullRequestChecksState
    public var isDraft: Bool?
}

/// Whether `gh` can be used; the UI shows a dedicated state for each failure.
public enum GitHubCLIStatus: Sendable, Equatable {
    case ready(executable: URL)
    case missing
    case signedOut
}

public enum GitHubPullRequestError: Error, Equatable, Sendable {
    case ghMissing
    case signedOut
    case parseFailed(String)
    case commandFailed(exitCode: Int32, stderr: String)
    case cancelled
    case invalidArgument(String)
}

// MARK: - Parsing

public enum GitHubPullRequestParser {
    /// Same fields upstream (`github_pr_list_mine`) requests from `gh search prs`.
    public static let searchFields = "number,title,url,repository,author,isDraft,updatedAt"
    public static let detailFields = "headRefOid,reviewDecision,statusCheckRollup,isDraft"

    /// Parses `gh search prs --json <searchFields>`. Entries without a number or repository are
    /// skipped; other missing fields get neutral defaults.
    public static func parseSearch(_ data: Data) throws -> [PullRequestSummary] {
        guard let array = try json(data) as? [[String: Any]] else {
            throw GitHubPullRequestError.parseFailed("expected a JSON array")
        }
        return array.compactMap { entry in
            guard let number = entry["number"] as? Int,
                  let repo = (entry["repository"] as? [String: Any])?["nameWithOwner"] as? String,
                  !repo.isEmpty
            else { return nil }
            return PullRequestSummary(
                number: number,
                title: entry["title"] as? String ?? "",
                repo: repo,
                url: (entry["url"] as? String).flatMap(URL.init(string:)),
                author: (entry["author"] as? [String: Any])?["login"] as? String ?? "",
                isDraft: entry["isDraft"] as? Bool ?? false,
                updatedAt: (entry["updatedAt"] as? String).flatMap(parseDate),
                reviewDecision: (entry["reviewDecision"] as? String).flatMap(PullRequestReviewDecision.init(rawValue:)),
                checks: checksState(entry["statusCheckRollup"]),
                headSHA: nonEmpty(entry["headRefOid"] as? String)
            )
        }
    }

    /// Parses `gh pr view --json <detailFields>`.
    public static func parseDetails(_ data: Data) throws -> PullRequestDetails {
        guard let object = try json(data) as? [String: Any] else {
            throw GitHubPullRequestError.parseFailed("expected a JSON object")
        }
        return PullRequestDetails(
            headSHA: nonEmpty(object["headRefOid"] as? String),
            reviewDecision: (object["reviewDecision"] as? String).flatMap(PullRequestReviewDecision.init(rawValue:)),
            checks: checksState(object["statusCheckRollup"]),
            isDraft: object["isDraft"] as? Bool
        )
    }

    /// Rolls up CheckRun (`status`/`conclusion`) and StatusContext (`state`) entries: any failure wins,
    /// then anything unfinished, then success.
    static func checksState(_ value: Any?) -> PullRequestChecksState {
        guard let entries = value as? [[String: Any]], !entries.isEmpty else { return .none }
        var pending = false
        for entry in entries {
            let state = ((entry["conclusion"] as? String).flatMap(nonEmpty)
                ?? (entry["state"] as? String)
                ?? (entry["status"] as? String) ?? "").uppercased()
            switch state {
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                return .failure
            case "SUCCESS", "NEUTRAL", "SKIPPED":
                continue
            default:
                pending = true
            }
        }
        return pending ? .pending : .success
    }

    private static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GitHubPullRequestError.parseFailed(error.localizedDescription)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

// MARK: - Commands

public enum GitHubPullRequestCommands {
    public static func searchArguments() -> [String] {
        ["search", "prs", "--involves=@me", "--state", "open", "--json", GitHubPullRequestParser.searchFields]
    }

    public static func detailArguments(repo: String, number: Int) throws -> [String] {
        try validate(repo: repo, number: number)
        return ["pr", "view", String(number), "-R", repo, "--json", GitHubPullRequestParser.detailFields]
    }

    /// Squash merge guarded by the reviewed head SHA (P4-15): GitHub refuses the merge if the branch
    /// moved after the review.
    public static func squashMergeArguments(pr: PullRequestSummary, headSHA: String) throws -> [String] {
        try validate(repo: pr.repo, number: pr.number)
        let sha = headSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 7, sha.count <= 64, sha.allSatisfy(\.isHexDigit) else {
            throw GitHubPullRequestError.invalidArgument(headSHA)
        }
        return ["pr", "merge", String(pr.number), "--squash", "--match-head-commit", sha, "-R", pr.repo]
    }

    static func validate(repo: String, number: Int) throws {
        guard number > 0 else { throw GitHubPullRequestError.invalidArgument(String(number)) }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || "-_.".contains(c)) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.allSatisfy(allowed) })
        else { throw GitHubPullRequestError.invalidArgument(repo) }
    }
}

// MARK: - Client

/// Runs `gh` with arguments; injectable so tests can fake outputs.
public protocol GitHubCLIRunning: Sendable {
    func run(_ arguments: [String]) async throws -> GitOutput
}

/// Runs the real `gh` through `GitRunner`, which terminates the process when the task is cancelled.
public struct GitHubCLIRunner: GitHubCLIRunning {
    public var executable: URL?

    public init(executable: URL? = GitHubCLIRunner.locateGh()) {
        self.executable = executable
    }

    public static func locateGh(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let dirs = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ arguments: [String]) async throws -> GitOutput {
        guard let executable else { throw GitHubPullRequestError.ghMissing }
        let runner = GitRunner(executable: executable, environment: [
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1",
        ])
        do {
            return try await runner.run(
                arguments, in: FileManager.default.homeDirectoryForCurrentUser, allowedExitCodes: Set(0...255)
            )
        } catch GitError.cancelled {
            throw GitHubPullRequestError.cancelled
        } catch GitError.gitMissing {
            throw GitHubPullRequestError.ghMissing
        }
    }
}

public struct GitHubPullRequests: Sendable {
    public var runner: any GitHubCLIRunning
    public var executable: URL?

    public init(runner: (any GitHubCLIRunning)? = nil, executable: URL? = GitHubCLIRunner.locateGh()) {
        self.executable = executable
        self.runner = runner ?? GitHubCLIRunner(executable: executable)
    }

    /// `missing` without a binary, `signedOut` when `gh auth status` fails.
    public func status() async throws -> GitHubCLIStatus {
        guard let executable else { return .missing }
        do {
            let output = try await runner.run(["auth", "status"])
            return Self.isSignedOut(output) ? .signedOut : .ready(executable: executable)
        } catch GitHubPullRequestError.ghMissing {
            return .missing
        }
    }

    /// Open PRs involving the signed-in user.
    public func listMine() async throws -> [PullRequestSummary] {
        guard executable != nil else { throw GitHubPullRequestError.ghMissing }
        let output = try await runner.run(GitHubPullRequestCommands.searchArguments())
        try Self.check(output)
        return try GitHubPullRequestParser.parseSearch(output.stdout)
    }

    /// Review decision, checks and head SHA for one PR.
    public func details(for pr: PullRequestSummary) async throws -> PullRequestDetails {
        guard executable != nil else { throw GitHubPullRequestError.ghMissing }
        let output = try await runner.run(GitHubPullRequestCommands.detailArguments(repo: pr.repo, number: pr.number))
        try Self.check(output)
        return try GitHubPullRequestParser.parseDetails(output.stdout)
    }

    /// Squash merges only if the PR head is still `headSHA`.
    public func squashMerge(_ pr: PullRequestSummary, headSHA: String) async throws {
        guard executable != nil else { throw GitHubPullRequestError.ghMissing }
        let output = try await runner.run(GitHubPullRequestCommands.squashMergeArguments(pr: pr, headSHA: headSHA))
        try Self.check(output)
    }

    static func isSignedOut(_ output: GitOutput) -> Bool {
        if output.exitCode != 0 { return true }
        let text = (output.text + "\n" + output.errorText).lowercased()
        return text.contains("not logged in")
    }

    static func check(_ output: GitOutput) throws {
        guard output.exitCode != 0 else { return }
        let message = output.errorText
        let lower = message.lowercased()
        if lower.contains("gh auth login") || lower.contains("not logged in") || lower.contains("authentication") {
            throw GitHubPullRequestError.signedOut
        }
        throw GitHubPullRequestError.commandFailed(exitCode: output.exitCode, stderr: message)
    }
}
