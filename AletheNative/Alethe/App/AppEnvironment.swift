import AletheAgents
import AletheDesign
import AletheFoundation
import AletheGitControl
import AletheModel
import AlethePluginKit
import AletheTodos
import AletheTerminal
import AletheThemePack
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
    /// Reviewed PR head SHAs and the review agent/model (P4-15).
    private(set) var pullRequestReviews: PullRequestReviewsModel?
    private(set) var locations: DataLocations?
    /// Built-in plugins of the active profile (P4-2); created by `load`.
    private(set) var plugins: PluginHost?
    /// Sheet requested by a menu, the sidebar or the workspace.
    var editorRequest: EditorRequest?
    /// The pane shown in focus mode (P2-21); not persisted.
    var focusModePaneID: PaneID?
    /// Home instead of the workspace (P3-15; ⇧⌘H).
    var showingHome = false
    /// The Settings pane shown.
    var settingsTab = SettingsTab.general
    /// Right sidebar (P4-3; ⌥⌘0), persisted across launches.
    var rightSidebarVisible = UserDefaults.standard.bool(forKey: "main.rightSidebarVisible") {
        didSet { UserDefaults.standard.set(rightSidebarVisible, forKey: "main.rightSidebarVisible") }
    }
    /// The right-sidebar tab shown; nil for the first one.
    var rightSidebarTab: String?
    /// Bumped to focus the new-todo field (the Todos plugin's "New Todo" command).
    var newTodoRequest = 0

    /// Launcher lookups are cached across terminals; hits are re-checked on disk.
    let launchers = LauncherCache()
    let terminals = TerminalRegistry()
    /// Memory supervision of the terminals (P2-24).
    let resources = ResourceMonitor()
    /// Agent CLI installs, one at a time (P3-3).
    let installer = AgentInstaller()
    /// Agent notifications and the in-app list (P3-11).
    let notifier = AgentNotifier()
    /// Ticks the Todos plugin's Pomodoro session and notifies phase ends (P4-17).
    let pomodoro = PomodoroController()
    /// AI usage of the providers (P3-13).
    let usage = UsageMonitor()
    /// Time analytics (P3-14).
    let activity = ActivityTracker()
    /// Dictation (P3-17).
    let dictation = DictationController()
    /// Models of open Markdown (and later other file) panes.
    let contentPanes = ContentPaneRegistry()
    /// The interface language this process launched with; Settings offers a relaunch when it changes.
    let launchLanguage = LanguageSetting().current()

    /// Dictation follows the interface language, in the user's region.
    var dictationLocale: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let code = Locale.Language(identifier: language).languageCode?.identifier ?? "en"
        return Locale(languageCode: .init(code), languageRegion: Locale.current.region)
    }

    var isLoaded: Bool { workspace != nil && preferences != nil }

    /// Built-in themes plus those contributed by active plugins, for the picker and resolution.
    var themeCatalog: ThemeCatalog {
        guard let plugins, !plugins.contributions.themes.isEmpty else { return .builtin }
        let contributed = plugins.contributions.themes
        if let cache = themeCatalogCache, cache.contributions == contributed { return cache.catalog }
        let catalog = ThemeCatalog.builtin.merging(contributions: contributed)
        themeCatalogCache = (contributed, catalog)
        return catalog
    }

    /// Decoding contributed themes on every `theme` read would be wasteful; keyed by the contributions.
    @ObservationIgnored private var themeCatalogCache: (contributions: [ThemeContribution], catalog: ThemeCatalog)?

    var theme: Theme {
        themeCatalog.resolved(id: preferences?.document.themeID ?? PreferencesDocument.defaultThemeID)
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
        async let reviews = PullRequestReviewsModel.load(from: locations.pullRequestReviews(profile))
        let (loadedWorkspace, loadedPreferences, loadedHistory) = await (workspace, preferences, promptHistory)
        pullRequestReviews = await reviews
        loadedWorkspace.update { $0.repair() }
        if loadedPreferences.document.startClean == true { loadedWorkspace.update { $0.startClean() } }
        showingHome = loadedPreferences.document.startOnHome == true && !loadedWorkspace.document.projects.isEmpty
        let tabs = Set(loadedWorkspace.document.projects.flatMap(\.panes).flatMap(\.tabs).map(\.id))
        if loadedHistory.document.histories.keys.contains(where: { !tabs.contains(TabID(rawValue: $0)) }) {
            loadedHistory.update { $0.prune(keeping: tabs) }
        }
        Self.removeOrphanScrollback(in: locations.scrollback(profile), keeping: tabs)
        Handoff.pruneOld(in: locations.handoffs(profile))
        // Plugins load before the preferences are published, so a pack theme applies on the first frame.
        let plugins = PluginHost(plugins: Self.builtinPlugins, dataRoot: locations.profileDirectory(profile),
                                 services: Self.pluginServices)
        TodosPlugin.onNewTodo = { [weak self] in
            guard let self else { return }
            self.showTodos()
            self.newTodoRequest += 1
        }
        GitControlPlugin.onOpen = { [weak self] in
            self?.openPluginSheet(GitControlPlugin.sheetID, project: nil)
        }
        await plugins.load()
        self.plugins = plugins
        #if DEBUG
        if let seed = UserDefaults.standard.string(forKey: "AletheUITestSeed"), loadedWorkspace.document.projects.isEmpty {
            loadedWorkspace.update { TestSeeds.apply(seed, to: &$0) }
        }
        // `-AletheUITestPreview <file name in the data root>`: opens the link preview at launch.
        if let name = UserDefaults.standard.string(forKey: "AletheUITestPreview") {
            editorRequest = .previewLink(.file(locations.root.appending(path: name).path))
        }
        #endif
        // The hook bridge listens before any terminal starts, so the first launches are wired too.
        terminals.hookEnvironment = self
        notifier.start(environment: self)
        pomodoro.start(environment: self)
        await terminals.hooks.start(terminals: terminals)
        self.profiles = profiles
        self.workspace = loadedWorkspace
        self.preferences = loadedPreferences
        self.promptHistory = loadedHistory
        resources.start(environment: self)
        usage.start(environment: self)
        activity.start(environment: self, file: locations.activityStats(profile))
        dictation.start(environment: self)
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
        await activity.finish()
        await plugins?.shutdown()
        terminals.terminateAll()
        terminals.hooks.stop()
        await workspace?.flush()
        await preferences?.flush()
        await promptHistory?.flush()
        await pullRequestReviews?.flush()
        await profiles?.flush()
    }

    /// The Todos plugin's store while it is enabled. Reading `plugins` first makes views observe
    /// enabling and disabling (the store itself is a static of the plugin).
    var todoStore: TodoStore? {
        guard plugins?.record(for: TodosPlugin.manifest.id)?.state == .active else { return nil }
        return TodosPlugin.activeStore
    }

    /// Opens the right sidebar on the Todos tab.
    func showTodos() {
        rightSidebarTab = TodosPlugin.sidebarTabID
        rightSidebarVisible = true
    }

    /// Host services behind plugin capabilities. File access is whole-file; writes create the folder.
    private static let pluginServices = PluginServices(
        readFile: { url in
            try await Task.detached { try Data(contentsOf: url) }.value
        },
        writeFile: { data, url in
            try await Task.detached {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }.value
        }
    )

    /// Plugins compiled into the app, in registration order.
    static let builtinPlugins: [any AlethePlugin.Type] = [ThemePackPlugin.self, TodosPlugin.self, GitControlPlugin.self]

    /// Whether an active plugin contributes the command `id`.
    func hasPluginCommand(_ id: String) -> Bool {
        plugins?.contributions.commands.contains { $0.id == id } == true
    }

    /// Runs an active plugin's command; nothing when its plugin is disabled.
    func performPluginCommand(_ id: String) {
        plugins?.contributions.commands.first { $0.id == id }?.perform()
    }

    /// Presents an active plugin's sheet for a project (nil: the selected one).
    func openPluginSheet(_ id: String, project: ProjectID?) {
        guard let sheet = plugins?.contributions.sheets.first(where: { $0.id == id }) else { return }
        editorRequest = .pluginSheet(viewID: sheet.viewID, project: project)
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
