import AletheDesign
import AletheFoundation
import AletheModel
import Foundation
import Observation

/// Composition root: the active profile's documents plus what the UI derives from them.
@Observable
@MainActor
final class AppEnvironment {
    private(set) var profiles: DocumentModel<ProfileIndexDocument>?
    private(set) var workspace: WorkspaceModel?
    private(set) var preferences: PreferencesModel?
    private(set) var locations: DataLocations?

    var isLoaded: Bool { workspace != nil && preferences != nil }

    var theme: Theme {
        ThemeCatalog.builtin.resolved(id: preferences?.document.themeID ?? PreferencesDocument.defaultThemeID)
    }

    var metrics: Metrics {
        Metrics(scale: CGFloat(preferences?.document.uiScale ?? 1))
    }

    func load() async {
        guard !isLoaded, let locations = try? Self.dataLocations() else { return }
        self.locations = locations
        let profiles = await DocumentModel<ProfileIndexDocument>.load(from: locations.profileIndex)
        let profile = profiles.document.activeProfile.id
        async let workspace = WorkspaceModel.load(from: locations.workspace(profile))
        async let preferences = PreferencesModel.load(from: locations.preferences(profile))
        let (loadedWorkspace, loadedPreferences) = await (workspace, preferences)
        loadedWorkspace.update { $0.repair() }
        #if DEBUG
        if let seed = UserDefaults.standard.string(forKey: "AletheUITestSeed"), loadedWorkspace.document.projects.isEmpty {
            loadedWorkspace.update { TestSeeds.apply(seed, to: &$0) }
        }
        #endif
        self.profiles = profiles
        self.workspace = loadedWorkspace
        self.preferences = loadedPreferences
    }

    /// Writes every pending change; called before the app quits.
    func flush() async {
        await workspace?.flush()
        await preferences?.flush()
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
