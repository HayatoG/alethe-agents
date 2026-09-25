import Foundation

public enum AgentLibraryError: Error, Equatable, Sendable {
    /// Not a single file name (empty, a path, or hidden).
    case invalidName(String)
    /// A file with that name exists without the Alethe marker; overwriting it needs the user's consent.
    case conflict(String)
    /// The file has no Alethe marker; removing it needs the user's consent.
    case notAlethe(String)
    case file(ConfigFileError)
}

/// What an operation did, so it can be undone (`AgentLibraryStore.revert`).
public struct AgentLibraryChange: Equatable, Sendable {
    public struct Edit: Equatable, Sendable {
        public let url: URL
        /// Contents before the change; `nil` when the file did not exist.
        public let previous: Data?
        /// Contents after the change; `nil` when the file was removed.
        public let current: Data?
    }

    public var edits: [Edit] = []
    /// File names left alone because they are not Alethe's (economy mode never overwrites or removes them).
    public var skipped: [String] = []

    public var isEmpty: Bool { edits.isEmpty }

    public init(edits: [Edit] = [], skipped: [String] = []) {
        self.edits = edits
        self.skipped = skipped
    }
}

/// Installs and removes Claude Code subagents under a scope's `.claude/agents` (upstream
/// `agent_library.rs` and `economy_agents.rs`). Every write and removal goes through
/// `ConfigFileWriter`: re-read first, backed up, atomic. Only files carrying the Alethe marker are
/// overwritten or removed unless the caller forces it after asking.
///
/// Every method does file I/O synchronously; call it off the main thread.
public struct AgentLibraryStore: Sendable {
    public let writer: ConfigFileWriter

    public init(writer: ConfigFileWriter) {
        self.writer = writer
    }

    /// Upstream refuses empty names and any `/`, `\` or `.`; a file stem may hold dots, so only
    /// separators, leading dots and `..` are refused here.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("..") && !name.contains("\0")
    }

    // MARK: Listing

    /// The `.md` agents of the scope, by name (upstream `list_installed_agents`).
    public func installed(in scope: AgentLibraryScope) -> [InstalledAgent] {
        let directory = scope.agentsDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .map { url in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return InstalledAgent(name: url.deletingPathExtension().lastPathComponent, url: url,
                                      fromAlethe: AletheAgentMarker.isAletheGenerated(text))
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: Library

    /// Writes `template` into the scope (upstream `install_agent`). An existing file without the
    /// marker throws `.conflict` unless `overwriteForeign` (the user agreed).
    @discardableResult
    public func install(_ template: AgentTemplate, in scope: AgentLibraryScope, overwriteForeign: Bool = false) throws(AgentLibraryError) -> AgentLibraryChange {
        guard Self.isValidName(template.name) else { throw .invalidName(template.name) }
        let url = scope.agentsDirectory.appending(path: template.fileName)
        let snapshot = try read(url)
        if snapshot.exists, !overwriteForeign, !AletheAgentMarker.isAletheGenerated(snapshot.text) {
            throw .conflict(template.name)
        }
        guard let edit = try write(template.content, over: snapshot, slot: scope.backupSlot) else { return AgentLibraryChange() }
        return AgentLibraryChange(edits: [edit])
    }

    /// Removes `<name>.md` (upstream `uninstall_agent`). A file without the marker throws
    /// `.notAlethe` unless `force` (the user agreed). A missing file is a no-op.
    @discardableResult
    public func uninstall(_ name: String, in scope: AgentLibraryScope, force: Bool = false) throws(AgentLibraryError) -> AgentLibraryChange {
        guard Self.isValidName(name) else { throw .invalidName(name) }
        let snapshot = try read(scope.agentsDirectory.appending(path: "\(name).md"))
        guard snapshot.exists else { return AgentLibraryChange() }
        if !force, !AletheAgentMarker.isAletheGenerated(snapshot.text) { throw .notAlethe(name) }
        return AgentLibraryChange(edits: [try remove(snapshot, slot: scope.backupSlot)])
    }

    // MARK: Economy mode

    /// On when every economy file is present (upstream `economy_agents_enabled`).
    public func economyEnabled(in scope: AgentLibraryScope) -> Bool {
        let directory = scope.agentsDirectory
        return EconomyAgents.files(for: scope).allSatisfy {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// Upstream `set_economy_agents`. On: writes the files (a user file with the same name is kept
    /// and reported, where upstream overwrote it) and removes upstream's Portuguese-named ones.
    /// Off: removes the files carrying the marker; the rest are kept and reported.
    @discardableResult
    public func setEconomy(_ enabled: Bool, in scope: AgentLibraryScope) throws(AgentLibraryError) -> AgentLibraryChange {
        let directory = scope.agentsDirectory
        var change = AgentLibraryChange()
        if enabled {
            for file in EconomyAgents.files(for: scope) {
                let snapshot = try read(directory.appending(path: file.fileName))
                if snapshot.exists, !EconomyAgents.isOwned(snapshot.text) {
                    change.skipped.append(file.fileName)
                    continue
                }
                if let edit = try write(file.content, over: snapshot, slot: scope.backupSlot) {
                    change.edits.append(edit)
                }
            }
        }
        let removals = (enabled ? [] : EconomyAgents.files(for: scope).map(\.fileName)) + EconomyAgents.legacyFileNames
        for name in removals {
            let snapshot = try read(directory.appending(path: name))
            guard snapshot.exists else { continue }
            guard EconomyAgents.isOwned(snapshot.text) else {
                if !enabled { change.skipped.append(name) }
                continue
            }
            change.edits.append(try remove(snapshot, slot: scope.backupSlot))
        }
        return change
    }

    // MARK: Undo

    /// Puts back what `change` replaced, newest edit first, and returns the change that redoes it.
    /// Refuses (`.file(.changedSinceRead)`) when a file changed after the operation.
    @discardableResult
    public func revert(_ change: AgentLibraryChange, backupSlot slot: ConfigBackupSlot?) throws(AgentLibraryError) -> AgentLibraryChange {
        var inverse = AgentLibraryChange()
        for edit in change.edits.reversed() {
            let snapshot = try read(edit.url)
            guard snapshot.contents == edit.current else { throw .file(.changedSinceRead(edit.url)) }
            if let previous = edit.previous {
                do {
                    try writer.write(previous, over: snapshot, backupSlot: slot)
                } catch {
                    throw .file(error)
                }
                inverse.edits.append(.init(url: edit.url, previous: edit.current, current: previous))
            } else {
                inverse.edits.append(try remove(snapshot, slot: slot))
            }
        }
        return inverse
    }

    // MARK: Files

    private func read(_ url: URL) throws(AgentLibraryError) -> ConfigFileSnapshot {
        do {
            return try writer.read(url)
        } catch {
            throw .file(error)
        }
    }

    /// Nil when the file already holds `text`.
    private func write(_ text: String, over snapshot: ConfigFileSnapshot, slot: ConfigBackupSlot) throws(AgentLibraryError) -> AgentLibraryChange.Edit? {
        let data = Data(text.utf8)
        guard snapshot.contents != data else { return nil }
        do {
            try writer.write(data, over: snapshot, backupSlot: slot)
        } catch {
            throw .file(error)
        }
        return .init(url: snapshot.url, previous: snapshot.contents, current: data)
    }

    private func remove(_ snapshot: ConfigFileSnapshot, slot: ConfigBackupSlot?) throws(AgentLibraryError) -> AgentLibraryChange.Edit {
        do {
            try writer.remove(over: snapshot, backupSlot: slot)
        } catch {
            throw .file(error)
        }
        return .init(url: snapshot.url, previous: snapshot.contents, current: nil)
    }
}
