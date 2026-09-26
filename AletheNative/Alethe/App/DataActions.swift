import AletheIntegrations
import AletheModel
import AppKit
import Foundation

/// Backup, import, reset and erase of the app's data (P5-10, upstream `backup.rs`, `diagnostics.rs`).
/// Anything that replaces or removes data takes a safety backup, is scheduled, and applies at the
/// relaunch before any document loads.
extension AppEnvironment {
    /// Archives the running profile (saved first) into `archive`.
    func exportBackup(to archive: URL) async throws {
        guard let locations, let profileID else { throw ProfileError.notFound }
        await saveDocuments()
        let folder = locations.profileDirectory(profileID), name = activeProfileName
        try await Task.detached { try ProfileBackup.export(folder, to: archive, profileName: name) }.value
    }

    /// Unpacks and validates an archive; nothing changes until `importStaged` is called.
    func stageBackup(_ archive: URL) async throws -> StagedBackup {
        guard let locations else { throw ProfileError.notFound }
        let staging = locations.importStaging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return try await Task.detached { try ProfileBackup.stage(archive, into: staging) }.value
    }

    /// Drops a staged archive the user did not import.
    func discardStaged(_ staged: StagedBackup) {
        let folder = staged.folder
        Task.detached { try? FileManager.default.removeItem(at: folder) }
    }

    /// Replaces the running profile with a staged archive at the relaunch.
    func importStaged(_ staged: StagedBackup) async throws {
        guard let profileID else { throw ProfileError.notFound }
        try await scheduleAfterSafetyBackup(.importProfile(profileID, stagedFolder: staged.folder.path))
    }

    /// Replaces the running profile with a validated gist pull (P7-11) at the relaunch.
    func importGistPull(_ pull: StagedGistPull) async throws {
        guard let profileID, case .importProfile(profileID, _) = pull.operation else { throw ProfileError.notFound }
        try await scheduleAfterSafetyBackup(pull.operation)
    }

    /// Empties the running profile (projects, settings, history, scrollback) at the relaunch.
    func resetProfileData() async throws {
        guard let profileID else { throw ProfileError.notFound }
        try await scheduleAfterSafetyBackup(.resetProfile(profileID))
    }

    /// Removes every profile and the profile index at the relaunch; safety backups stay.
    func eraseAllData() async throws {
        try await scheduleAfterSafetyBackup(.eraseAll)
    }

    func openDataFolder() {
        guard let locations else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(locations.root)
    }

    func revealSafetyBackups() {
        guard let locations else { return }
        try? FileManager.default.createDirectory(at: locations.safetyBackups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(locations.safetyBackups)
    }

    private func scheduleAfterSafetyBackup(_ operation: PendingDataOperation) async throws {
        guard let locations, let profileID else { throw ProfileError.notFound }
        await saveDocuments()
        let name = activeProfileName
        try await Task.detached {
            switch operation {
            case .eraseAll:
                try ProfileBackup.safetyBackup(of: locations.root, label: "all-data", into: locations.safetyBackups,
                                               profileName: nil, skipping: DataMaintenance.maintenanceEntries(locations))
            case .importProfile, .resetProfile:
                try ProfileBackup.safetyBackup(of: locations.profileDirectory(profileID), label: "profile-\(profileID.rawValue)",
                                               into: locations.safetyBackups, profileName: name)
            }
            try DataMaintenance.schedule(operation, in: locations)
        }.value
        relaunch()
    }
}

extension BackupError {
    var localizedMessage: String {
        switch self {
        case .targetInsideSource: String(localized: "settings.data.error.insideProfile")
        case .unreadableArchive: String(localized: "settings.data.error.unreadable")
        case .unsafeEntry(let name): String(format: String(localized: "settings.data.error.unsafe"), name)
        case .notAProfileBackup: String(localized: "settings.data.error.notBackup")
        case .tauriBackup: String(localized: "settings.data.error.tauri")
        case .newerFormat: String(localized: "settings.data.error.newer")
        case .archiveFailed(let message): String(format: String(localized: "settings.data.error.archive"), message)
        }
    }
}
