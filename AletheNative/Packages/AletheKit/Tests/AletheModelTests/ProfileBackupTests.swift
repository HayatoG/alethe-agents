import Foundation
import Testing
@testable import AletheModel

/// Backup, import, reset and erase (P5-10). Every case runs in its own temporary data root.
@Suite struct ProfileBackupTests {
    private let root: URL
    private let locations: DataLocations
    private let profile = ProfileID(rawValue: "main")

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "alethe-backup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        locations = DataLocations(root: root)
    }

    private func write(_ text: String, _ relative: String, in folder: URL) throws {
        let url = folder.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String, in folder: URL) -> String? {
        (try? Data(contentsOf: folder.appending(path: relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A profile with two projects, three tabs, scrollback and runtime leftovers.
    private func seedProfile() throws -> URL {
        let folder = locations.profileDirectory(profile)
        var document = WorkspaceDocument.initial
        let a = document.addProject(name: "alpha", folder: "/tmp/a")
        document.addPane(to: a, tab: PaneTab(agent: "claude"))
        document.addPane(to: a, tab: PaneTab(agent: "shell"))
        let b = document.addProject(name: "beta", folder: "/tmp/b")
        document.addPane(to: b, tab: PaneTab(agent: "codex"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(document).write(to: locations.workspace(profile))
        try write(#"{"schemaVersion":1}"#, "preferences.json", in: folder)
        try write("output", "scrollback/tab.bin", in: folder)
        try write("partial", "workspace.json.tmp", in: folder)
        try write("debug", "spawn.log", in: folder)
        return folder
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func exportAndImportRoundTrip() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        let archive = root.appending(path: "exports/backup.zip")
        try ProfileBackup.export(folder, to: archive, profileName: "Work", now: Date(timeIntervalSince1970: 1_000))

        let entries = try ProfileBackup.entries(of: archive)
        #expect(entries.contains("workspace.json") && entries.contains("scrollback/tab.bin"))
        #expect(entries.contains(BackupManifest.fileName))
        #expect(!entries.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".log") }, "runtime files are left out")

        let staged = try ProfileBackup.stage(archive, into: locations.importStaging.appending(path: "one"))
        #expect(staged.contents.projects == 2 && staged.contents.terminals == 3)
        #expect(staged.contents.hasScrollback)
        #expect(staged.contents.manifest?.profileName == "Work")
        #expect(staged.contents.manifest?.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(!FileManager.default.fileExists(atPath: staged.folder.appending(path: BackupManifest.fileName).path))

        // The profile changes after the export; the import brings the exported state back.
        try write("changed", "scrollback/tab.bin", in: folder)
        try write("new", "scrollback/other.bin", in: folder)
        try DataMaintenance.schedule(.importProfile(profile, stagedFolder: staged.folder.path), in: locations)
        let applied = try DataMaintenance.applyPending(in: locations)
        #expect(applied == .importProfile(profile, stagedFolder: staged.folder.path))
        #expect(read("scrollback/tab.bin", in: folder) == "output")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "scrollback/other.bin").path))
        #expect(ProfileFiles.counts(ofWorkspaceAt: locations.workspace(profile)) == (2, 3))
        #expect(!FileManager.default.fileExists(atPath: locations.pendingOperation.path))
        #expect(!FileManager.default.fileExists(atPath: locations.importStaging.path))
        #expect(try DataMaintenance.applyPending(in: locations) == nil)
    }

    @Test func exclusionsFollowUpstream() {
        #expect(ProfileFiles.isRuntimeFile(relativePath: "EBWebView/Default/LOCK"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "projects.json.tmp"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "logs/app.log"))
        #expect(!ProfileFiles.isRuntimeFile(relativePath: "scrollback/session.bin"))
    }

    @Test func corruptArchiveIsRefusedBeforeAnythingIsRemoved() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        let archive = root.appending(path: "broken.zip")
        try Data("PK\u{3}\u{4} not really a zip".utf8).write(to: archive)
        let staging = locations.importStaging.appending(path: "broken")
        #expect(throws: BackupError.unreadableArchive) { try ProfileBackup.stage(archive, into: staging) }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(read("scrollback/tab.bin", in: folder) == "output")
        #expect(ProfileFiles.counts(ofWorkspaceAt: locations.workspace(profile)) == (2, 3))
        #expect(DataMaintenance.pending(in: locations) == nil)
    }

    @Test func archivesWithoutAProfileAreRefused() throws {
        defer { cleanup() }
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try write("{}", "notes.json", in: other)
        let archive = root.appending(path: "other.zip")
        try ProfileBackup.export(other, to: archive, profileName: nil)
        #expect(throws: BackupError.notAProfileBackup) {
            try ProfileBackup.stage(archive, into: locations.importStaging.appending(path: "x"))
        }

        let tauri = root.appending(path: "tauri", directoryHint: .isDirectory)
        try write(#"{"projects":[]}"#, "projects.json", in: tauri)
        let tauriArchive = root.appending(path: "tauri.zip")
        try ProfileBackup.export(tauri, to: tauriArchive, profileName: nil)
        #expect(throws: BackupError.tauriBackup) {
            try ProfileBackup.stage(tauriArchive, into: locations.importStaging.appending(path: "y"))
        }

        let newer = root.appending(path: "newer", directoryHint: .isDirectory)
        try write(#"{"schemaVersion":999,"projects":[]}"#, "workspace.json", in: newer)
        let newerArchive = root.appending(path: "newer.zip")
        try ProfileBackup.export(newer, to: newerArchive, profileName: nil)
        #expect(throws: BackupError.newerFormat) {
            try ProfileBackup.stage(newerArchive, into: locations.importStaging.appending(path: "z"))
        }
    }

    @Test func aFolderArchiveIsUnwrapped() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        // Finder's Compress keeps the folder itself as the archive's top level.
        let archive = root.appending(path: "finder.zip")
        try ProfileBackup.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, archive.path])
        let staged = try ProfileBackup.stage(archive, into: locations.importStaging.appending(path: "finder"))
        #expect(staged.contents.projects == 2)
        #expect(FileManager.default.fileExists(atPath: staged.folder.appending(path: "workspace.json").path))
        #expect(!FileManager.default.fileExists(atPath: staged.folder.appending(path: "spawn.log").path))
    }

    @Test func unsafeEntriesAreRecognized() {
        #expect(ProfileBackup.isUnsafe(entry: "/etc/passwd"))
        #expect(ProfileBackup.isUnsafe(entry: "../outside.json"))
        #expect(ProfileBackup.isUnsafe(entry: "scrollback/../../x"))
        #expect(ProfileBackup.isUnsafe(entry: "..\\windows.json"))
        #expect(!ProfileBackup.isUnsafe(entry: "scrollback/tab.bin"))
        #expect(!ProfileBackup.isUnsafe(entry: "notes..json"))
    }

    @Test func aBackupIsNeverWrittenInsideItsSource() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        #expect(throws: BackupError.targetInsideSource) {
            try ProfileBackup.export(folder, to: folder.appending(path: "self.zip"), profileName: nil)
        }
        #expect(throws: BackupError.targetInsideSource) {
            try ProfileBackup.export(folder, to: folder.appending(path: "scrollback/self.zip"), profileName: nil)
        }
        // The data root's own safety-backups folder is fine: it is left out of the archive.
        let archive = try ProfileBackup.safetyBackup(of: root, label: "all-data", into: locations.safetyBackups,
                                                     profileName: nil, skipping: DataMaintenance.maintenanceEntries(locations))
        #expect(!(try ProfileBackup.entries(of: archive)).contains { $0.hasPrefix("safety-backups") })
    }

    @Test func safetyBackupsKeepTheNewestTen() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        for second in 0..<12 {
            try ProfileBackup.safetyBackup(of: folder, label: "profile-main", into: locations.safetyBackups,
                                           profileName: nil, now: Date(timeIntervalSince1970: TimeInterval(second)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: locations.safetyBackups.path).sorted()
        #expect(names.count == ProfileBackup.keptSafetyBackups)
        #expect(names.first == "profile-main-19700101-000002-000.zip")
    }

    @Test func resetEmptiesOnlyThatProfile() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        let other = ProfileID(rawValue: "other")
        try write("{}", "workspace.json", in: locations.profileDirectory(other))
        try DataMaintenance.schedule(.resetProfile(profile), in: locations)
        #expect(try DataMaintenance.applyPending(in: locations) == .resetProfile(profile))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: locations.workspace(other).path))
    }

    @Test func eraseKeepsOnlyTheSafetyBackups() throws {
        defer { cleanup() }
        _ = try seedProfile()
        try write("{}", "profiles.json", in: root)
        let backup = try ProfileBackup.safetyBackup(of: root, label: "all-data", into: locations.safetyBackups,
                                                    profileName: nil, skipping: DataMaintenance.maintenanceEntries(locations))
        try DataMaintenance.schedule(.eraseAll, in: locations)
        #expect(try DataMaintenance.applyPending(in: locations) == .eraseAll)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left == [locations.safetyBackups.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aStagedFolderOutsideTheStagingAreaIsRefused() throws {
        defer { cleanup() }
        let folder = try seedProfile()
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try write("{}", "workspace.json", in: elsewhere)
        try DataMaintenance.schedule(.importProfile(profile, stagedFolder: elsewhere.path), in: locations)
        #expect(throws: BackupError.notAProfileBackup) { try DataMaintenance.applyPending(in: locations) }
        #expect(read("scrollback/tab.bin", in: folder) == "output")
        #expect(DataMaintenance.pending(in: locations) == nil, "a failed operation is not retried")
    }

    @Test func cancellingClearsTheSchedule() throws {
        defer { cleanup() }
        try DataMaintenance.schedule(.resetProfile(profile), in: locations)
        try FileManager.default.createDirectory(at: locations.importStaging, withIntermediateDirectories: true)
        DataMaintenance.cancelPending(in: locations)
        #expect(DataMaintenance.pending(in: locations) == nil)
        #expect(!FileManager.default.fileExists(atPath: locations.importStaging.path))
    }
}
