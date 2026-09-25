import AletheGit
import Foundation

/// One branch test: the validation pipeline, the optional health probe and the contract check,
/// run in a temporary checkout of the branch (upstream `BranchTestingModal`'s automated part).
public struct BranchTestResult: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case passed, failed, cancelled, unverified
    }

    public var branch: String
    public var commit: String
    public var validation: ValidationReport
    public var healthProbe: HealthProbeResult?
    public var contractWarnings: [ContractWarning]
    public var finishedAt: Date

    public init(branch: String, commit: String, validation: ValidationReport, healthProbe: HealthProbeResult?,
                contractWarnings: [ContractWarning], finishedAt: Date = Date()) {
        self.branch = branch
        self.commit = commit
        self.validation = validation
        self.healthProbe = healthProbe
        self.contractWarnings = contractWarnings
        self.finishedAt = finishedAt
    }

    /// The validation status; the probe and the contract check are warnings, never failures.
    public var status: Status {
        switch validation.status {
        case .passed: .passed
        case .failed: .failed
        case .cancelled: .cancelled
        case .unverified: .unverified
        }
    }

    public var hasWarnings: Bool {
        !contractWarnings.isEmpty || (healthProbe.map { !$0.healthy } ?? false)
    }
}

/// Branch test results kept per branch, newest last, at most `limit` each; Codable for persistence.
public struct BranchTestLog: Codable, Equatable, Sendable {
    public static let limit = 10
    public private(set) var results: [String: [BranchTestResult]] = [:]

    public init() {}

    public mutating func record(_ result: BranchTestResult) {
        var list = results[result.branch, default: []]
        list.append(result)
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        results[result.branch] = list
    }

    public func latest(for branch: String) -> BranchTestResult? { results[branch]?.last }
    public func history(for branch: String) -> [BranchTestResult] { results[branch] ?? [] }
    public mutating func forget(branch: String) { results[branch] = nil }

    /// `<repo>/.alethe/branch-tests/results.json`.
    public static func fileURL(root: URL) -> URL {
        BranchTester.directory(root: root).appendingPathComponent("results.json")
    }

    /// The saved log, or an empty one when missing or unreadable.
    public static func load(root: URL) -> BranchTestLog {
        guard let data = try? Data(contentsOf: fileURL(root: root)) else { return BranchTestLog() }
        return (try? JSONDecoder().decode(BranchTestLog.self, from: data)) ?? BranchTestLog()
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: BranchTester.directory(root: root), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL(root: root), options: .atomic)
    }
}

/// Long steps reported while testing a branch.
public enum BranchTestStep: String, Sendable, Hashable, CaseIterable {
    case checkingOut, validating, probing, checkingContract, cleaningUp
}

/// Checks a branch out into a throwaway detached worktree under `.alethe/branch-tests/`, runs the
/// project's checks there and always removes the worktree. The user's tree is never touched.
public struct BranchTester: Sendable {
    public let root: URL
    public let runner: GitRunner
    public let validator: ValidationRunner
    public let probe: HealthProbe

    public init(root: URL, runner: GitRunner = GitRunner(), validator: ValidationRunner = ValidationRunner(),
                probe: HealthProbe = HealthProbe()) {
        self.root = root
        self.runner = runner
        self.validator = validator
        self.probe = probe
    }

    public static func directory(root: URL) -> URL {
        root.appendingPathComponent(".alethe/branch-tests", isDirectory: true)
    }

    public func test(
        branch: String,
        settings: ValidationSettings,
        progress: (@Sendable (BranchTestStep) -> Void)? = nil,
        onStep: (@Sendable (ValidationStepResult) -> Void)? = nil
    ) async throws -> BranchTestResult {
        try await MergeAnalyzer(root: root, runner: runner).ensureBranch(branch)
        let base = Self.directory(root: root)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent("test-\(ConflictResolution.newID())", isDirectory: true)

        progress?(.checkingOut)
        _ = try await runner.run(["worktree", "add", "--detach", dir.path, branch], in: root)
        do {
            let commit = try await runner.run(["rev-parse", "HEAD"], in: dir).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            progress?(.validating)
            let report = await validator.run(settings.effectiveCommands, in: dir, onStep: onStep)
            var probeResult: HealthProbeResult?
            if report.status != .cancelled, !Task.isCancelled, let command = settings.healthCheckCommand,
               !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                progress?(.probing)
                probeResult = try? await probe.run(in: dir, startCommand: command, path: settings.healthCheckPath)
            }
            progress?(.checkingContract)
            let warnings = Task.isCancelled ? [] : ((try? ContractCheck.check(root: dir)) ?? [])
            progress?(.cleaningUp)
            await teardown(dir)
            return BranchTestResult(branch: branch, commit: commit, validation: report,
                                    healthProbe: probeResult, contractWarnings: warnings)
        } catch {
            await teardown(dir)
            throw error
        }
    }

    /// Best-effort; runs even if the calling task was cancelled.
    private func teardown(_ dir: URL) async {
        let root = root, runner = runner
        await Task.detached {
            _ = try? await runner.run(["worktree", "remove", "--force", "--force", dir.path], in: root)
            try? FileManager.default.removeItem(at: dir)
            _ = try? await runner.run(["worktree", "prune"], in: root)
        }.value
    }
}
