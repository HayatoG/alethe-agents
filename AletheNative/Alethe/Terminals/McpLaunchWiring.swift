import AletheAgents
import AletheModel
import Foundation

/// What a provider sees when deciding which MCP servers a launch gets.
struct McpLaunchContext {
    var tab: TabID
    var kind: AgentKind
    var project: Project
    var workingDirectory: String
}

/// Per-launch MCP wiring (P5-4): integrations register a provider (Graphify, ai-memory and
/// Playwright plug in later), and each agent launch gets their servers without touching the user's
/// or the project's config. Claude and OpenCode read them from a private file written here.
@MainActor
final class McpLaunchWiring {
    typealias Provider = @MainActor (McpLaunchContext) -> [McpLaunchServer]

    private let folder: URL
    /// In registration order, so the first provider wins a name both use.
    private var providers: [(id: String, provider: Provider)] = []

    init(folder: URL = AgentHookHub.folder) {
        self.folder = folder
    }

    /// Adds or replaces the provider registered under `id`.
    func register(_ id: String, _ provider: @escaping Provider) {
        if let index = providers.firstIndex(where: { $0.id == id }) {
            providers[index].provider = provider
        } else {
            providers.append((id, provider))
        }
    }

    func unregister(_ id: String) {
        providers.removeAll { $0.id == id }
    }

    /// Servers for one launch and, for agents that read a file, its path; empty when nothing applies
    /// or the file could not be written (the agent then starts without them).
    func launch(for context: McpLaunchContext) -> (servers: [McpLaunchServer], configPath: String?) {
        guard McpLaunchConfig.supports(context.kind), !providers.isEmpty else { return ([], nil) }
        let servers = McpLaunchServer.deduplicated(providers.flatMap { $0.provider(context) })
        guard !servers.isEmpty else { return ([], nil) }
        guard let data = McpLaunchConfig.file(for: context.kind, servers: servers) else { return (servers, nil) }
        let file = folder.appending(path: "mcp-\(context.kind.rawValue)-\(context.tab.rawValue).json")
        guard Self.writePrivately(data, to: file, folder: folder) else { return ([], nil) }
        return (servers, file.path)
    }

    /// Atomic (tmp → rename) 0600 write. Local until P5-1's `ConfigFileWriter` lands; these files
    /// are Alethe's own per-run files, so no backup or conflict check applies.
    private static func writePrivately(_ data: Data, to file: URL, folder: URL) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary.path, file.path) == 0 else {
            try? manager.removeItem(at: temporary)
            return false
        }
        return true
    }
}
