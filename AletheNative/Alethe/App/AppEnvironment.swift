import AletheAgents
import AletheDesign
import AletheFoundation
import AletheModel
import AletheTerminal
import Foundation
import Observation

/// Composition root: the active profile's documents plus what the UI derives from them.
@Observable
@MainActor
final class AppEnvironment {
    private(set) var profiles: DocumentModel<ProfileIndexDocument>?
    private(set) var workspace: WorkspaceModel?
    private(set) var preferences: PreferencesModel?
    private(set) var promptHistory: PromptHistoryModel?
    private(set) var locations: DataLocations?
    /// Sheet requested by a menu, the sidebar or the workspace.
    var editorRequest: EditorRequest?

    /// Launcher lookups are cached across terminals; hits are re-checked on disk.
    let launchers = LauncherCache()
    let terminals = TerminalRegistry()
    /// The interface language this process launched with; Settings offers a relaunch when it changes.
    let launchLanguage = LanguageSetting().current()

    var isLoaded: Bool { workspace != nil && preferences != nil }

    var theme: Theme {
        ThemeCatalog.builtin.resolved(id: preferences?.document.themeID ?? PreferencesDocument.defaultThemeID)
    }

    /// Terminal text follows the UI zoom.
    var terminalFontSize: Float {
        TerminalAppearance.defaultFontSize * Float(preferences?.document.uiScale ?? 1)
    }

    var metrics: Metrics {
        Metrics(scale: CGFloat(preferences?.document.uiScale ?? 1))
    }

    /// Builds agent commands with the user's CLI path overrides.
    var agentLauncher: AgentLauncher {
        AgentLauncher(launchers: launchers, overrides: preferences?.document.cliPaths ?? [:])
    }

    func load() async {
        guard !isLoaded, let locations = try? Self.dataLocations() else { return }
        self.locations = locations
        let profiles = await DocumentModel<ProfileIndexDocument>.load(from: locations.profileIndex)
        let profile = profiles.document.activeProfile.id
        async let workspace = WorkspaceModel.load(from: locations.workspace(profile))
        async let preferences = PreferencesModel.load(from: locations.preferences(profile))
        async let promptHistory = PromptHistoryModel.load(from: locations.promptHistory(profile))
        let (loadedWorkspace, loadedPreferences, loadedHistory) = await (workspace, preferences, promptHistory)
        loadedWorkspace.update { $0.repair() }
        let tabs = Set(loadedWorkspace.document.projects.flatMap(\.panes).flatMap(\.tabs).map(\.id))
        if loadedHistory.document.histories.keys.contains(where: { !tabs.contains(TabID(rawValue: $0)) }) {
            loadedHistory.update { $0.prune(keeping: tabs) }
        }
        Self.removeOrphanScrollback(in: locations.scrollback(profile), keeping: tabs)
        #if DEBUG
        if let seed = UserDefaults.standard.string(forKey: "AletheUITestSeed"), loadedWorkspace.document.projects.isEmpty {
            loadedWorkspace.update { TestSeeds.apply(seed, to: &$0) }
        }
        #endif
        self.profiles = profiles
        self.workspace = loadedWorkspace
        self.preferences = loadedPreferences
        self.promptHistory = loadedHistory
    }

    /// The saved output of a terminal tab (`scrollback/<tab>.bin` in the active profile).
    func scrollbackFile(for tab: TabID) -> ScrollbackFile? {
        guard let locations, let profile = profiles?.document.activeProfile.id else { return nil }
        return ScrollbackFile(url: locations.scrollback(profile).appending(path: "\(tab.rawValue).bin"))
    }

    /// Scrollback of tabs that no longer exist (closed while the app was not running, or by undo).
    private static func removeOrphanScrollback(in directory: URL, keeping tabs: Set<TabID>) {
        let names = Set(tabs.map { "\($0.rawValue).bin" })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "bin" && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Writes every pending change; called before the app quits.
    func flush() async {
        terminals.terminateAll()
        await workspace?.flush()
        await preferences?.flush()
        await promptHistory?.flush()
        await profiles?.flush()
    }

    /// `-AletheDataRoot <path>` (debug builds) points the app at another data folder: UI tests and
    /// manual experiments never touch the real one.
    private static func dataLocations() throws -> DataLocations {
        #if DEBUG
        if let root = UserDefaults.standard.string(forKey: "AletheDataRoot") {
            return DataLocations(root: URL(filePath: root, directoryHint: .isDirectory))
        }
        #endif
        return try DataLocations.application()
    }
}
