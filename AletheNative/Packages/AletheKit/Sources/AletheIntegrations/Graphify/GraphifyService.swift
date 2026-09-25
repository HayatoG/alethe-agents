import Foundation

/// Whether the Graphify CLI answers (upstream `GraphifyStatus`).
public struct GraphifyStatus: Hashable, Sendable {
    public var available: Bool
    /// The executable probed; nil when it could not be resolved at all.
    public var executable: String?
    /// `--version`'s trimmed output.
    public var version: String?

    public init(available: Bool, executable: String?, version: String? = nil) {
        self.available = available
        self.executable = executable
        self.version = version
    }
}

/// What `ensureGraph` found or did (upstream `graphify_ensure_graph`'s strings).
public enum GraphifyEnsureResult: String, Sendable {
    case exists, generating, unavailable, started
}

/// How a generation ended.
public enum GraphifyGenerationOutcome: Equatable, Sendable {
    case generated
    case failed(String)
    case cancelled
    case timedOut
}

/// The Graphify CLI side of upstream `graphify.rs`: detection, generation (one run per repository,
/// cancelable), the MCP server launch arguments, and async access to `GraphifyRepository` off the
/// caller's thread.
public actor GraphifyService {
    public static let defaultCommand = "graphify"
    public static let probeTimeout: Duration = .seconds(10)
    /// Graphify reads the whole repository; large ones take minutes.
    public static let generationTimeout: Duration = .seconds(15 * 60)

    private var generations: [URL: Task<GraphifyGenerationOutcome, Never>] = [:]
    private let generationTimeout: Duration

    public init(generationTimeout: Duration = GraphifyService.generationTimeout) {
        self.generationTimeout = generationTimeout
    }

    /// The MCP server agents launch for a repository (upstream `mcp_server_spec`): `<cli> <root> --mcp`.
    public nonisolated static func mcpArguments(root: URL) -> [String] {
        [root.standardizedFileURL.path, "--mcp"]
    }

    /// Upstream `graphify_detect`: `--version` succeeds.
    public nonisolated func detect(executable: String?) async -> GraphifyStatus {
        guard let executable else { return GraphifyStatus(available: false, executable: nil) }
        guard let result = try? await ExternalCommand.run(executable, ["--version"], timeout: Self.probeTimeout),
              result.succeeded else {
            return GraphifyStatus(available: false, executable: executable)
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return GraphifyStatus(available: true, executable: executable, version: version.isEmpty ? nil : version)
    }

    public func isGenerating(_ root: URL) -> Bool { generations[root.standardizedFileURL] != nil }

    /// Upstream `graphify_ensure_graph`: nothing when the graph exists or is being generated; else the
    /// CLI is probed and a generation starts in the background. `onFinish` gets its outcome.
    public func ensureGraph(root: URL, executable: String?,
                            onFinish: (@Sendable (GraphifyGenerationOutcome) -> Void)? = nil) async -> GraphifyEnsureResult {
        let root = root.standardizedFileURL
        let repository = GraphifyRepository(root: root)
        if await Task.detached(operation: { repository.hasGraph }).value { return .exists }
        if generations[root] != nil { return .generating }
        guard await detect(executable: executable).available, let executable else { return .unavailable }
        // The probe awaited: another call may have started one meanwhile.
        if generations[root] != nil { return .generating }
        startGeneration(root: root, executable: executable, onFinish: onFinish)
        return .started
    }

    /// Generates (or regenerates) the graph, waiting for the run; joins a run already going.
    public func generate(root: URL, executable: String) async -> GraphifyGenerationOutcome {
        let root = root.standardizedFileURL
        let task = generations[root] ?? startGeneration(root: root, executable: executable, onFinish: nil)
        return await task.value
    }

    /// Stops a running generation; its outcome is `.cancelled`.
    public func cancelGeneration(root: URL) {
        generations[root.standardizedFileURL]?.cancel()
    }

    @discardableResult
    private func startGeneration(root: URL, executable: String,
                                 onFinish: (@Sendable (GraphifyGenerationOutcome) -> Void)?) -> Task<GraphifyGenerationOutcome, Never> {
        let timeout = generationTimeout
        // Runs on this actor (only awaiting the process), so it starts after `generations` is set.
        let task = Task<GraphifyGenerationOutcome, Never> {
            let outcome: GraphifyGenerationOutcome
            do {
                let result = try await ExternalCommand.run(executable, [root.path], directory: root, timeout: timeout)
                outcome = result.succeeded ? .generated
                    : .failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch ExternalCommandError.cancelled {
                outcome = .cancelled
            } catch ExternalCommandError.timedOut {
                outcome = .timedOut
            } catch ExternalCommandError.launchFailed(let message) {
                outcome = .failed(message)
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            self.finished(root)
            onFinish?(outcome)
            return outcome
        }
        generations[root] = task
        return task
    }

    private func finished(_ root: URL) { generations[root] = nil }

    // MARK: - Files, off the caller's thread

    public nonisolated func readGraph(root: URL, limit: Int = GraphData.visualizationLimit) async throws -> GraphData {
        try await Self.detached { try GraphifyRepository(root: root).readGraph(limit: limit) }
    }

    public nonisolated func snapshot(root: URL) async throws -> GraphSnapshot {
        try await Self.detached { try GraphifyRepository(root: root).snapshot() }
    }

    public nonisolated func snapshots(root: URL) async -> [GraphSnapshot] {
        await Task.detached { GraphifyRepository(root: root).snapshots() }.value
    }

    public nonisolated func diff(root: URL, base: String, compare: String? = nil) async throws -> GraphDiff {
        try await Self.detached { try GraphifyRepository(root: root).diff(base: base, compare: compare) }
    }

    public nonisolated func rollback(root: URL, to id: String) async throws {
        try await Self.detached { try GraphifyRepository(root: root).rollback(to: id) }
    }

    @discardableResult
    public nonisolated func prune(root: URL, keepLast: Int, maxAgeDays: Int? = nil) async -> Int {
        await Task.detached { GraphifyRepository(root: root).prune(keepLast: keepLast, maxAgeDays: maxAgeDays) }.value
    }

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(operation: work).value
    }
}
