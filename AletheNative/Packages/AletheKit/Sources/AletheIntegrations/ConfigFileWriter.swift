import Foundation

/// A config file as it was read: its bytes and modification date, or its absence.
public struct ConfigFileSnapshot: Sendable, Equatable {
    public let url: URL
    /// `nil` when the file did not exist.
    public let contents: Data?
    public let modificationDate: Date?

    public var exists: Bool { contents != nil }
    /// The contents as UTF-8 text; empty for a missing file.
    public var text: String { contents.map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// Where a file's backups go: `<profile>/config-backups/<agent>-<kind>/`, e.g. `claude-user`,
/// `codex-project` (upstream `mcp_store.rs` names backups `<agent>-<kind>-<ms>.<ext>`).
public struct ConfigBackupSlot: Hashable, Sendable {
    public let agent: String
    public let kind: String

    public init(agent: String, kind: String) {
        self.agent = Self.sanitize(agent)
        self.kind = Self.sanitize(kind)
    }

    public var name: String { "\(agent)-\(kind)" }

    /// Keeps names to one path component of `[a-z0-9_]`.
    private static func sanitize(_ value: String) -> String {
        let cleaned = value.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9", "_": Character(scalar)
            default: "_"
            }
        }
        return cleaned.isEmpty ? "_" : String(cleaned)
    }
}

public struct ConfigBackup: Hashable, Sendable, Identifiable {
    public let url: URL
    public let slot: ConfigBackupSlot
    public let createdAt: Date
    public let size: Int

    public var id: URL { url }
}

public struct ConfigWriteReport: Sendable, Equatable {
    public let url: URL
    /// The copy of the previous contents; `nil` when the file did not exist.
    public let backup: ConfigBackup?
}

public enum ConfigFileError: Error, Equatable, Sendable {
    /// The file on disk is not the one that was read: someone edited, created or removed it.
    /// Nothing was written; re-read and apply the change again.
    case changedSinceRead(URL)
    case unreadable(URL, String)
    case backupFailed(URL, String)
    case writeFailed(URL, String)
}

/// Reads and writes the agents' config files that live outside the profile (`~/.claude.json`,
/// `.mcp.json`, `~/.codex/config.toml`, …). Upstream `mcp_store.rs` `backup`/`prune_backups`/
/// `atomic_write`, plus a guard upstream lacks: a write is refused when the file changed since it
/// was read, so an outside edit is never overwritten blind.
///
/// Every method does file I/O synchronously; call it off the main thread.
public struct ConfigFileWriter: Sendable {
    /// Upstream `MAX_BACKUPS`, per slot.
    public static let maxBackups = 10
    public static let backupsFolderName = "config-backups"

    public let backupRoot: URL
    private let now: @Sendable () -> Date

    public init(profileDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(backupRoot: profileDirectory.appending(path: Self.backupsFolderName, directoryHint: .isDirectory), now: now)
    }

    public init(backupRoot: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backupRoot = backupRoot
        self.now = now
    }

    // MARK: Reading

    public func read(_ url: URL) throws(ConfigFileError) -> ConfigFileSnapshot {
        let target = Self.resolved(url)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else {
            return ConfigFileSnapshot(url: url, contents: nil, modificationDate: nil)
        }
        do {
            let date = try fileManager.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
            let data = try Data(contentsOf: target)
            return ConfigFileSnapshot(url: url, contents: data, modificationDate: date)
        } catch {
            throw .unreadable(url, error.localizedDescription)
        }
    }

    // MARK: Writing

    /// Writes `data` over the file `snapshot` was read from: re-reads it and refuses when it changed,
    /// backs up the current contents into `slot` (pruned to `maxBackups`), then writes atomically
    /// (temporary sibling renamed over the file, keeping its permissions). A symlinked file is
    /// written through the link.
    @discardableResult
    public func write(_ data: Data, over snapshot: ConfigFileSnapshot, backupSlot slot: ConfigBackupSlot?) throws(ConfigFileError) -> ConfigWriteReport {
        let current = try read(snapshot.url)
        guard current == snapshot else { throw .changedSinceRead(snapshot.url) }
        var backup: ConfigBackup?
        if let contents = current.contents, let slot {
            backup = try store(contents, of: snapshot.url, in: slot)
        }
        try Self.atomicWrite(data, to: Self.resolved(snapshot.url))
        return ConfigWriteReport(url: snapshot.url, backup: backup)
    }

    /// Writes `text` (UTF-8) over the snapshot; see `write(_:over:backupSlot:)`.
    @discardableResult
    public func write(_ text: String, over snapshot: ConfigFileSnapshot, backupSlot slot: ConfigBackupSlot?) throws(ConfigFileError) -> ConfigWriteReport {
        try write(Data(text.utf8), over: snapshot, backupSlot: slot)
    }

    // MARK: Backups

    /// A slot's backups, newest first.
    public func backups(in slot: ConfigBackupSlot) -> [ConfigBackup] {
        let folder = folder(for: slot)
        let prefix = slot.name + "-"
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url -> ConfigBackup? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let stamp = name.dropFirst(prefix.count).prefix { $0.isNumber }
            guard let milliseconds = Int64(stamp) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ConfigBackup(
                url: url,
                slot: slot,
                createdAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
                size: size
            )
        }
        .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Puts a backup's contents back into `url`. The current contents are backed up first (into the
    /// backup's slot), so a restore can itself be undone. The caller asks before restoring.
    @discardableResult
    public func restore(_ backup: ConfigBackup, to url: URL) throws(ConfigFileError) -> ConfigWriteReport {
        let data: Data
        do {
            data = try Data(contentsOf: backup.url)
        } catch {
            throw .unreadable(backup.url, error.localizedDescription)
        }
        return try write(data, over: read(url), backupSlot: backup.slot)
    }

    private func folder(for slot: ConfigBackupSlot) -> URL {
        backupRoot.appending(path: slot.name, directoryHint: .isDirectory)
    }

    private func store(_ contents: Data, of url: URL, in slot: ConfigBackupSlot) throws(ConfigFileError) -> ConfigBackup {
        let folder = folder(for: slot)
        let fileManager = FileManager.default
        let fileExtension = url.pathExtension.isEmpty ? "bak" : url.pathExtension
        do {
            // Backups hold secrets (MCP env values): owner-only folder.
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var milliseconds = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
            var target: URL
            repeat {
                // Zero-padded so name order is time order (pruning and listing sort by name).
                target = folder.appending(path: "\(slot.name)-\(String(format: "%015lld", milliseconds)).\(fileExtension)")
                milliseconds += 1
            } while fileManager.fileExists(atPath: target.path)
            try contents.write(to: target, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            prune(slot)
            return ConfigBackup(
                url: target,
                slot: slot,
                createdAt: Date(timeIntervalSince1970: TimeInterval(milliseconds - 1) / 1000),
                size: contents.count
            )
        } catch {
            throw .backupFailed(url, error.localizedDescription)
        }
    }

    /// Upstream `prune_backups`: keeps the newest `maxBackups` of the slot.
    private func prune(_ slot: ConfigBackupSlot) {
        for stale in backups(in: slot).dropFirst(Self.maxBackups) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    // MARK: Atomic write

    /// Resolves a symlinked config (dotfile repositories) so the rename replaces the real file, not
    /// the link.
    static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    static func atomicWrite(_ data: Data, to url: URL) throws(ConfigFileError) {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).alethe-tmp-\(UUID().uuidString.prefix(8))")
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: temporary, options: .withoutOverwriting)
            // A fresh file gets the default mode, which would widen a config the user locked to 0600.
            if let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw .writeFailed(url, error.localizedDescription)
        }
    }
}
