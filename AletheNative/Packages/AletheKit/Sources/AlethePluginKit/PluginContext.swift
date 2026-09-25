import Foundation

/// Host services behind capabilities. The app fills these in; a nil service makes the matching
/// context call throw `PluginError.serviceUnavailable`.
public struct PluginServices: Sendable {
    public var runGit: (@Sendable (_ arguments: [String], _ directory: URL) async throws -> String)?
    public var readFile: (@Sendable (URL) async throws -> Data)?
    public var writeFile: (@Sendable (Data, URL) async throws -> Void)?
    public var sendTerminalInput: (@Sendable (_ text: String, _ terminalID: String) async throws -> Void)?
    public var urlSession: URLSession?

    public init(
        runGit: (@Sendable ([String], URL) async throws -> String)? = nil,
        readFile: (@Sendable (URL) async throws -> Data)? = nil,
        writeFile: (@Sendable (Data, URL) async throws -> Void)? = nil,
        sendTerminalInput: (@Sendable (String, String) async throws -> Void)? = nil,
        urlSession: URLSession? = nil
    ) {
        self.runGit = runGit
        self.readFile = readFile
        self.writeFile = writeFile
        self.sendTerminalInput = sendTerminalInput
        self.urlSession = urlSession
    }
}

/// The only surface a plugin sees. Every host service checks the manifest's capabilities first;
/// contributions are staged and only published by the host once `activate` returns.
@MainActor
public final class PluginContext {
    public let manifest: PluginManifest
    private let services: PluginServices
    private let storageProvider: () -> PluginStorage
    private(set) var contributions = PluginContributions()
    /// Cleared when the plugin is deactivated; later calls throw `PluginError.inactive`.
    var isActive = true

    init(manifest: PluginManifest, services: PluginServices, storage: @escaping () -> PluginStorage) {
        self.manifest = manifest
        self.services = services
        self.storageProvider = storage
    }

    public func hasCapability(_ capability: PluginCapability) -> Bool {
        manifest.capabilities.contains(capability)
    }

    /// Throws unless the context is live and `capability` is declared in the manifest.
    public func require(_ capability: PluginCapability) throws {
        guard isActive else { throw PluginError.inactive(pluginID: manifest.id) }
        guard hasCapability(capability) else {
            throw PluginError.undeclaredCapability(capability, pluginID: manifest.id)
        }
    }

    // MARK: Capability-gated services

    public func storage() throws -> PluginStorage {
        try require(.storage)
        return storageProvider()
    }

    public func runGit(_ arguments: [String], in directory: URL) async throws -> String {
        try require(.git)
        guard let runGit = services.runGit else { throw PluginError.serviceUnavailable(.git) }
        return try await runGit(arguments, directory)
    }

    public func readFile(at url: URL) async throws -> Data {
        try require(.filesystemRead)
        guard let readFile = services.readFile else { throw PluginError.serviceUnavailable(.filesystemRead) }
        return try await readFile(url)
    }

    public func writeFile(_ data: Data, to url: URL) async throws {
        try require(.filesystemWrite)
        guard let writeFile = services.writeFile else { throw PluginError.serviceUnavailable(.filesystemWrite) }
        try await writeFile(data, url)
    }

    public func sendTerminalInput(_ text: String, toTerminal terminalID: String) async throws {
        try require(.terminalInput)
        guard let send = services.sendTerminalInput else { throw PluginError.serviceUnavailable(.terminalInput) }
        try await send(text, terminalID)
    }

    public func urlSession() throws -> URLSession {
        try require(.network)
        guard let session = services.urlSession else { throw PluginError.serviceUnavailable(.network) }
        return session
    }

    // MARK: Contributions

    public func addSidebarTab(_ tab: SidebarTabContribution) throws {
        try checkNew(tab.id, kind: "sidebarTab", in: contributions.sidebarTabs.map(\.id))
        contributions.sidebarTabs.append(tab)
    }

    public func addCommand(_ command: CommandContribution) throws {
        try checkNew(command.id, kind: "command", in: contributions.commands.map(\.id))
        contributions.commands.append(command)
    }

    public func addTheme(_ theme: ThemeContribution) throws {
        try checkNew(theme.id, kind: "theme", in: contributions.themes.map(\.id))
        contributions.themes.append(theme)
    }

    public func addPaneKind(_ paneKind: PaneKindContribution) throws {
        try checkNew(paneKind.id, kind: "paneKind", in: contributions.paneKinds.map(\.id))
        contributions.paneKinds.append(paneKind)
    }

    public func addSheet(_ sheet: SheetContribution) throws {
        try checkNew(sheet.id, kind: "sheet", in: contributions.sheets.map(\.id))
        contributions.sheets.append(sheet)
    }

    public func addSettingsPage(_ page: SettingsPageContribution) throws {
        try checkNew(page.id, kind: "settingsPage", in: contributions.settingsPages.map(\.id))
        contributions.settingsPages.append(page)
    }

    public func addAgentProvider(_ provider: AgentProviderContribution) throws {
        try checkNew(provider.id, kind: "agentProvider", in: contributions.agentProviders.map(\.id))
        contributions.agentProviders.append(provider)
    }

    private func checkNew(_ id: String, kind: String, in existing: [String]) throws {
        guard isActive else { throw PluginError.inactive(pluginID: manifest.id) }
        guard !existing.contains(id) else { throw PluginError.duplicateContribution(kind: kind, id: id) }
    }
}
