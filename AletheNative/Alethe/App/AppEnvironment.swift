import AletheAgents
import AletheDesign
import AletheFoundation
import AletheModel
import AletheTerminal
import AppKit
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
    /// The pane shown in focus mode (P2-21); not persisted.
    var focusModePaneID: PaneID?

    /// Launcher lookups are cached across terminals; hits are re-checked on disk.
    let launchers = LauncherCache()
    let terminals = TerminalRegistry()
    /// Memory supervision of the terminals (P2-24).
    let resources = ResourceMonitor()
    /// Models of open Markdown (and later other file) panes.
    let contentPanes = ContentPaneRegistry()
    /// The interface language this process launched with; Settings offers a relaunch when it changes.
    let launchLanguage = LanguageSetting().current()

    var isLoaded: Bool { workspace != nil && preferences != nil }

    var theme: Theme {
        ThemeCatalog.builtin.resolved(id: preferences?.document.themeID ?? PreferencesDocument.defaultThemeID)
            .styled(visualStyle)
    }

    var visualStyle: VisualStyle {
        preferences?.document.visualStyle.flatMap(VisualStyle.init(rawValue:)) ?? .normal
    }

    /// macOS Reduce Motion, kept current by `load`.
    private(set) var systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Reduced motion by preference or by macOS Reduce Motion (upstream `motionPreference`).
    var reducesMotion: Bool { preferences?.document.reducedMotion == true || systemReducesMotion }

    /// Terminal text follows the UI zoom.
    var terminalFontSize: Float {
        TerminalAppearance.defaultFontSize * Float(preferences?.document.uiScale ?? 1)
    }

    var metrics: Metrics {
        Metrics(scale: CGFloat(preferences?.document.uiScale ?? 1), style: visualStyle, reducesMotion: reducesMotion)
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
        if loadedPreferences.document.startClean == true { loadedWorkspace.update { $0.startClean() } }
        let tabs = Set(loadedWorkspace.document.projects.flatMap(\.panes).flatMap(\.tabs).map(\.id))
        if loadedHistory.document.histories.keys.contains(where: { !tabs.contains(TabID(rawValue: $0)) }) {
            loadedHistory.update { $0.prune(keeping: tabs) }
        }
        Self.removeOrphanScrollback(in: locations.scrollback(profile), keeping: tabs)
        #if DEBUG
        if let seed = UserDefaults.standard.string(forKey: "AletheUITestSeed"), loadedWorkspace.document.projects.isEmpty {
            loadedWorkspace.update { TestSeeds.apply(seed, to: &$0) }
        }
        // `-AletheUITestPreview <file name in the data root>`: opens the link preview at launch.
        if let name = UserDefaults.standard.string(forKey: "AletheUITestPreview") {
            editorRequest = .previewLink(.file(locations.root.appending(path: name).path))
        }
        #endif
        self.profiles = profiles
        self.workspace = loadedWorkspace
        self.preferences = loadedPreferences
        self.promptHistory = loadedHistory
        resources.start(environment: self)
        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: NSWorkspace.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
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

    /// Running terminals, agents counted apart (the quit confirmation names them).
    var runningTerminals: (agents: Int, shells: Int) {
        guard let document = workspace?.document else { return (0, 0) }
        var agents = 0, shells = 0
        for (tab, _) in terminals.running {
            if document.paneHolding(tab)?.pane.tabs.first(where: { $0.id == tab })?.agent == "shell" { shells += 1 } else { agents += 1 }
        }
        return (agents, shells)
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
