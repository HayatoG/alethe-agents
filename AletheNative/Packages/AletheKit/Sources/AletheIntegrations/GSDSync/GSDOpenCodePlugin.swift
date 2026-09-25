import Foundation

/// What `GSDOpenCodePlugin.install` did to each file.
public struct GSDPluginInstallReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case written
        case unchanged
        /// Left alone: a user-edited plugin, a newer Alethe's plugin, or an `opencode.json` that is
        /// not a JSON object or whose `plugin` key is not a list.
        case skipped
    }

    public var plugin: Outcome
    public var modelChain: Outcome
    public var openCodeConfig: Outcome
    /// The `opencode.json` backup taken before it was changed.
    public var configBackup: ConfigBackup?
}

/// Installs the GSD Sync OpenCode plugin into a worktree (upstream `opencode_gsd_plugin.rs`): the
/// `alethe-gsd-state.ts` plugin (upstream's asset, managed by its `// alethe-managed: v<N>` first
/// line), the `.opencode/alethe-gsd-config.json` model chain the plugin reads at runtime, and the
/// plugin entry merged into `opencode.json`. Runs synchronously; call it off the main thread.
public enum GSDOpenCodePlugin {
    public static let pluginRelativePath = ".opencode/plugins/alethe-gsd-state.ts"
    public static let configEntry = "./.opencode/plugins/alethe-gsd-state.ts"
    public static let modelChainRelativePath = ".opencode/alethe-gsd-config.json"
    public static let openCodeConfigName = "opencode.json"
    public static let schemaURL = "https://opencode.ai/config.json"
    static let markerPrefix = "// alethe-managed: v"
    /// Backups of the project's `opencode.json` before Alethe edits it.
    public static let backupSlot = ConfigBackupSlot(agent: "opencode", kind: "project")

    public enum InstallError: Error, Equatable, Sendable {
        case pluginAssetMissing
        case file(ConfigFileError)
    }

    /// The plugin source shipped with the app (copied verbatim from upstream).
    public static func bundledPlugin() throws(InstallError) -> String {
        guard let url = Bundle.module.url(forResource: "alethe-gsd-state", withExtension: "ts", subdirectory: "OpenCodePlugins"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { throw .pluginAssetMissing }
        return text
    }

    /// The version in a plugin's first line; nil when it has no Alethe marker.
    public static func managedVersion(of content: String) -> Int? {
        guard let first = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.hasPrefix(markerPrefix) else { return nil }
        return UInt32(first.dropFirst(markerPrefix.count).trimmingCharacters(in: .whitespaces)).map(Int.init)
    }

    /// Upstream `should_write_plugin_file`: a missing file is written, an Alethe-managed one of this
    /// version or older is replaced, anything else (a user-edited file, a newer Alethe's) is kept.
    public static func shouldWritePlugin(existing: String?, bundledVersion: Int) -> Bool {
        guard let existing else { return true }
        guard let version = managedVersion(of: existing) else { return false }
        return version <= bundledVersion
    }

    /// Installs into the checkout at `root`. `pluginSource` defaults to the bundled plugin.
    @discardableResult
    public static func install(
        root: URL,
        modelChain: [String],
        writer: ConfigFileWriter,
        pluginSource: String? = nil
    ) throws(InstallError) -> GSDPluginInstallReport {
        let source: String
        if let pluginSource { source = pluginSource } else { source = try bundledPlugin() }
        do throws(ConfigFileError) {
            let plugin = try writePlugin(source, root: root, writer: writer)
            let chain = try writeModelChain(modelChain, root: root, writer: writer)
            let (config, backup) = try mergeConfigEntry(root: root, writer: writer)
            return GSDPluginInstallReport(plugin: plugin, modelChain: chain, openCodeConfig: config, configBackup: backup)
        } catch {
            throw .file(error)
        }
    }

    static func writePlugin(_ source: String, root: URL, writer: ConfigFileWriter) throws(ConfigFileError) -> GSDPluginInstallReport.Outcome {
        let snapshot = try writer.read(root.appending(path: pluginRelativePath))
        guard shouldWritePlugin(existing: snapshot.exists ? snapshot.text : nil, bundledVersion: managedVersion(of: source) ?? 0) else {
            return .skipped
        }
        guard snapshot.text != source || !snapshot.exists else { return .unchanged }
        // Alethe owns this file; no backup.
        try writer.write(source, over: snapshot, backupSlot: nil)
        return .written
    }

    /// Rewritten on every install so a changed chain in Settings reaches the next run.
    static func writeModelChain(_ chain: [String], root: URL, writer: ConfigFileWriter) throws(ConfigFileError) -> GSDPluginInstallReport.Outcome {
        let snapshot = try writer.read(root.appending(path: modelChainRelativePath))
        let body = OrderedJSON.object(OrderedJSONObject([("modelChain", .array(chain.map(OrderedJSON.string)))])).rendered()
        guard !snapshot.exists || snapshot.text != body else { return .unchanged }
        try writer.write(body, over: snapshot, backupSlot: nil)
        return .written
    }

    /// Adds the plugin entry to `opencode.json`'s `plugin` list, keeping every other key; creates the
    /// file (with `$schema`) when missing. One retry when the file changes between read and write.
    static func mergeConfigEntry(root: URL, writer: ConfigFileWriter) throws(ConfigFileError) -> (GSDPluginInstallReport.Outcome, ConfigBackup?) {
        let url = root.appending(path: openCodeConfigName)
        var attempt = 0
        while true {
            attempt += 1
            let snapshot = try writer.read(url)
            guard let text = mergedConfig(snapshot.exists ? snapshot.text : nil) else { return (.skipped, nil) }
            guard text != snapshot.text || !snapshot.exists else { return (.unchanged, nil) }
            do throws(ConfigFileError) {
                let report = try writer.write(text, over: snapshot, backupSlot: backupSlot)
                return (.written, report.backup)
            } catch .changedSinceRead where attempt < 2 {
                continue
            }
        }
    }

    /// The config text with the plugin entry; the unchanged text when it is already listed; nil when
    /// the file must be left alone (not a JSON object, or `plugin` is not a list).
    static func mergedConfig(_ existing: String?) -> String? {
        var editor: JSONConfigEditor
        if let existing {
            guard let parsed = try? JSONConfigEditor(parsing: existing) else { return nil }
            editor = parsed
        } else {
            editor = JSONConfigEditor(root: OrderedJSONObject([("$schema", .string(schemaURL))]))
        }
        var list: [OrderedJSON]
        switch editor.value(at: ["plugin"]) {
        case .none: list = []
        case .array(let items): list = items
        case .some: return nil
        }
        if list.contains(.string(configEntry)) { return existing ?? editor.rendered() }
        list.append(.string(configEntry))
        guard (try? editor.set(.array(list), at: ["plugin"])) != nil else { return nil }
        return editor.rendered()
    }
}
