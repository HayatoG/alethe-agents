import AletheAgents
import AletheFoundation
import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// Graphify for the app (EXT-5, P5-17): resolves the CLI, detects it, generates graphs one run per
/// repository, and adds `graphify <root> --mcp` to agent launches of projects that turned Graphify on
/// while the feature is on (per-launch wiring, P5-4, instead of upstream's writes to the project's
/// `opencode.json` and `.codex/config.toml`). The Graphify view (P5-23) reads graphs and snapshots
/// through it.
@Observable
@MainActor
final class GraphifyController {
    static let mcpServerName = "graphify"

    @ObservationIgnored let service = GraphifyService()
    /// The last detection; nil until the first finished.
    private(set) var status: GraphifyStatus?
    private(set) var isDetecting = false
    /// Repositories whose graph is being generated.
    private(set) var generating: Set<URL> = []
    /// Bumped when a repository's graph file changed (generated, rolled back), so views reload it.
    private(set) var revisions: [URL: Int] = [:]
    /// The last generation failure per repository, cleared by the next success.
    private(set) var failures: [URL: String] = [:]
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var roots: [String: URL] = [:]
    /// `GraphUpdated` on generation and rollback (P6-19).
    @ObservationIgnored private let events = EventOutbox()

    func start(environment: AppEnvironment) {
        self.environment = environment
        events.attach(environment.multiagent.bus)
        environment.terminals.mcp.register(Self.mcpServerName) { [weak self] context in
            self?.servers(for: context) ?? []
        }
    }

    /// The configured CLI: a command name found like the agents' CLIs, or a path used as is (a
    /// missing path is not replaced by a lookup: the user asked for that file).
    var executable: String? {
        guard let environment else { return nil }
        let configured = environment.preferences?.document.graphifyCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        if configured.isEmpty { return environment.launchers.resolve(GraphifyService.defaultCommand) }
        guard configured.contains("/") || configured.hasPrefix("~") else { return environment.launchers.resolve(configured) }
        let path = (configured as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func detect() async {
        isDetecting = true
        let executable = executable
        status = await service.detect(executable: executable)
        isDetecting = false
    }

    /// The repository holding `directory` (cached); the directory itself outside a repository.
    func root(for directory: String) -> URL {
        if let cached = roots[directory] { return cached }
        let url = URL(filePath: directory, directoryHint: .isDirectory)
        // Only hits are kept: a folder may become a repository later (`git init`).
        guard let root = GraphifyRepository.repositoryRoot(containing: url) else { return url.standardizedFileURL }
        roots[directory] = root
        return root
    }

    func isGenerating(_ root: URL) -> Bool { generating.contains(root.standardizedFileURL) }

    /// Starts a generation when the repository has no graph yet (upstream bootstrap on launch).
    func ensureGraph(root: URL) {
        let root = root.standardizedFileURL
        let executable = executable
        let wasGenerating = generating.contains(root)
        generating.insert(root)
        Task {
            let result = await service.ensureGraph(root: root, executable: executable) { outcome in
                Task { @MainActor [weak self] in self?.finished(root, outcome, action: "bootstrap") }
            }
            if result == .exists || result == .unavailable, !wasGenerating { generating.remove(root) }
        }
    }

    /// Generates the graph again (the view's Generate/Regenerate) and waits for it.
    @discardableResult
    func generate(root: URL) async -> GraphifyGenerationOutcome {
        let root = root.standardizedFileURL
        guard let executable else {
            let outcome = GraphifyGenerationOutcome.failed(String(localized: "graphify.notFound"))
            failures[root] = String(localized: "graphify.notFound")
            return outcome
        }
        generating.insert(root)
        let outcome = await service.generate(root: root, executable: executable)
        finished(root, outcome, action: "generate")
        return outcome
    }

    func cancelGeneration(root: URL) {
        Task { await service.cancelGeneration(root: root.standardizedFileURL) }
    }

    /// Puts a snapshot back as the current graph. The view asks before calling.
    func rollback(root: URL, to snapshot: String) async throws {
        try await service.rollback(root: root, to: snapshot)
        revisions[root.standardizedFileURL, default: 0] += 1
        events.publish(.graphRolledBack(snapshotID: snapshot))
    }

    /// `action` is the `GraphUpdated` action published on success.
    private func finished(_ root: URL, _ outcome: GraphifyGenerationOutcome, action: String) {
        generating.remove(root)
        switch outcome {
        case .generated:
            failures[root] = nil
            revisions[root, default: 0] += 1
            events.publish(.graphGenerated(repository: root.path, action: action))
        case .failed(let message):
            failures[root] = message.isEmpty ? String(localized: "graphify.generationFailed") : message
            AppLog.record(.warning, .integrations, "Graphify generation failed: \(message)")
        case .timedOut:
            failures[root] = String(localized: "graphify.generationTimedOut")
            AppLog.record(.warning, .integrations, "Graphify generation timed out")
        case .cancelled:
            break
        }
    }

    /// The Graphify MCP server for one launch, and the graph generated if it is missing.
    private func servers(for context: McpLaunchContext) -> [McpLaunchServer] {
        guard let environment, environment.features.isOn(.graphify), context.project.usesGraphify,
              McpLaunchConfig.supports(context.kind), let executable else { return [] }
        let root = root(for: context.workingDirectory)
        ensureGraph(root: root)
        return [McpLaunchServer(name: Self.mcpServerName, command: executable,
                                arguments: GraphifyService.mcpArguments(root: root))]
    }
}
