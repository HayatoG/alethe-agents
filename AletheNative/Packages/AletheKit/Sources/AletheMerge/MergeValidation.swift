import AletheGit
import Foundation

/// A project's validation settings (upstream `Project.validationCommands`/`healthCheckCommand`/path).
/// Upstream leaves them user-configured; `suggested(for:)` only pre-fills an empty editor.
public struct ValidationSettings: Codable, Equatable, Sendable {
    public var commands: [String]
    public var healthCheckCommand: String?
    public var healthCheckPath: String?

    public init(commands: [String] = [], healthCheckCommand: String? = nil, healthCheckPath: String? = nil) {
        self.commands = commands
        self.healthCheckCommand = healthCheckCommand
        self.healthCheckPath = healthCheckPath
    }

    /// Non-empty trimmed commands, in order.
    public var effectiveCommands: [String] {
        commands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Build/test commands inferred from well-known manifests at `root` (native-only convenience).
    public static func suggested(for root: URL) -> ValidationSettings {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
        var commands: [String] = []
        if exists("package.json"),
           let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            let runner = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn" : "npm"
            if scripts["build"] != nil { commands.append("\(runner) run build") }
            if scripts["test"] != nil { commands.append(runner == "npm" ? "npm test" : "\(runner) test") }
        }
        if exists("Cargo.toml") { commands += ["cargo build", "cargo test"] }
        if exists("Package.swift") { commands += ["swift build", "swift test"] }
        if exists("go.mod") { commands += ["go build ./...", "go test ./..."] }
        return ValidationSettings(commands: commands)
    }
}

/// One command's captured run.
public struct ValidationStepResult: Codable, Equatable, Sendable {
    public var command: String
    public var exitCode: Int32
    public var output: String
    public var durationMs: Int

    public var succeeded: Bool { exitCode == 0 }
}

/// The outcome of a validation pipeline (upstream `ValidationResult`), kept per merge.
public struct ValidationReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case passed, failed, cancelled
        /// No command configured: nothing was checked (not a blocker, but never shown as "validated").
        case unverified
    }

    public var status: Status
    public var steps: [ValidationStepResult]
    public var healthProbe: HealthProbeResult?
    public var finishedAt: Date

    /// The failing command (upstream `stage`), if any.
    public var failedCommand: String? { steps.first { !$0.succeeded }?.command }
    public var ranAnyCommand: Bool { !steps.isEmpty }
}

/// Runs validation commands in a directory with `/bin/sh -c`, stopping at the first failure
/// (upstream `run_validation`). Cancelling the calling task terminates the running command.
public struct ValidationRunner: Sendable {
    public static let maxOutput = 64 * 1024
    /// Shell exit statuses (and signal numbers) are 0...255; all of them are reported, not thrown.
    static let anyExit = Set<Int32>(0...255)
    public var shell: URL
    public var environment: [String: String]

    public init(shell: URL = URL(fileURLWithPath: "/bin/sh"), environment: [String: String] = [:]) {
        self.shell = shell
        self.environment = environment
    }

    public func run(
        _ commands: [String],
        in directory: URL,
        onStep: (@Sendable (ValidationStepResult) -> Void)? = nil
    ) async -> ValidationReport {
        let runner = GitRunner(executable: shell, environment: environment)
        var steps: [ValidationStepResult] = []
        for command in commands.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !command.isEmpty {
            if Task.isCancelled { return report(.cancelled, steps) }
            let start = Date()
            let step: ValidationStepResult
            do {
                let out = try await runner.run(["-c", command], in: directory, allowedExitCodes: Self.anyExit)
                step = ValidationStepResult(
                    command: command, exitCode: out.exitCode,
                    output: Self.combined(out.stdout, out.stderr), durationMs: Self.ms(since: start))
            } catch GitError.cancelled {
                return report(.cancelled, steps)
            } catch {
                step = ValidationStepResult(
                    command: command, exitCode: -1, output: String(describing: error), durationMs: Self.ms(since: start))
            }
            steps.append(step)
            onStep?(step)
            if !step.succeeded { return report(.failed, steps) }
        }
        return report(steps.isEmpty ? .unverified : .passed, steps)
    }

    private func report(_ status: ValidationReport.Status, _ steps: [ValidationStepResult]) -> ValidationReport {
        ValidationReport(status: status, steps: steps, healthProbe: nil, finishedAt: Date())
    }

    static func combined(_ stdout: Data, _ stderr: Data) -> String {
        var text = String(decoding: stdout, as: UTF8.self)
        let err = String(decoding: stderr, as: UTF8.self)
        if !err.isEmpty { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + err }
        return HealthProbe.capped(text, limit: maxOutput)
    }

    static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

/// Validation results kept per merge environment id; Codable so the Merge Center can persist them.
public struct MergeValidationLog: Codable, Equatable, Sendable {
    public private(set) var reports: [String: [ValidationReport]] = [:]

    public init() {}

    public mutating func record(_ report: ValidationReport, forMerge id: String) {
        reports[id, default: []].append(report)
    }

    public func latest(forMerge id: String) -> ValidationReport? { reports[id]?.last }

    public mutating func forget(merge id: String) { reports[id] = nil }
}
