import AletheFoundation
import Foundation

/// A plugin's key-value store, persisted as `plugin-data/<id>.json`.
///
/// Changes are debounced; each write goes to a temporary sibling that is renamed over the file, so
/// a crash never leaves a half-written store. An unreadable file is moved aside and the store
/// starts empty.
public actor PluginStorage {
    public nonisolated let url: URL
    private let debounce: Duration
    private var values: JSONObject?
    private var dirty = false
    private var debounceTask: Task<Void, Never>?
    /// Number of files written, for tests.
    private(set) var writeCount = 0

    public init(url: URL, debounce: Duration = .milliseconds(300)) {
        self.url = url
        self.debounce = debounce
    }

    /// The store of plugin `id` under `root` (`<root>/plugin-data/<id>.json`).
    public init(root: URL, pluginID: String, debounce: Duration = .milliseconds(300)) {
        self.init(url: root.appending(path: "plugin-data", directoryHint: .isDirectory)
            .appending(path: "\(pluginID).json"), debounce: debounce)
    }

    public func value(forKey key: String) -> JSONValue? {
        loaded()[key]
    }

    public var allValues: JSONObject { loaded() }

    /// Sets (or, with nil, removes) a value and schedules a debounced write.
    public func set(_ value: JSONValue?, forKey key: String) {
        var current = loaded()
        current[key] = value
        values = current
        dirty = true
        scheduleWrite()
    }

    public func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let value = loaded()[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    public func encode<T: Encodable>(_ value: T, forKey key: String) throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        set(json, forKey: key)
    }

    /// Writes pending changes now (on disable and on quit).
    public func flush() throws {
        debounceTask?.cancel()
        debounceTask = nil
        try writeIfDirty()
    }

    private func scheduleWrite() {
        debounceTask?.cancel()
        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            try? self.writeIfDirty()
        }
    }

    private func loaded() -> JSONObject {
        if let values { return values }
        let fileManager = FileManager.default
        var result: JSONObject = [:]
        if fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONDecoder().decode(JSONObject.self, from: data) {
                result = object
            } else {
                let aside = url.deletingLastPathComponent()
                    .appending(path: url.lastPathComponent + ".corrupt-\(UUID().uuidString.prefix(8))")
                try? fileManager.moveItem(at: url, to: aside)
            }
        }
        values = result
        return result
    }

    private func writeIfDirty() throws {
        guard dirty, let values else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        // rename(2) replaces the target atomically.
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        dirty = false
        writeCount += 1
    }
}
