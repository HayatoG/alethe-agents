import Foundation
import Testing
@testable import AletheFoundation
@testable import AlethePluginKit

private struct Settings: Codable, Equatable {
    var interval: Int
    var labels: [String]
}

@Suite struct PluginStorageTests {
    @Test func roundTripsThroughTheFile() async throws {
        let root = temporaryDirectory()
        let storage = PluginStorage(root: root, pluginID: "test.store")
        #expect(storage.url.path.hasSuffix("plugin-data/test.store.json"))
        await storage.set(.string("hi"), forKey: "greeting")
        try await storage.encode(Settings(interval: 25, labels: ["a", "b"]), forKey: "settings")
        try await storage.flush()

        let reopened = PluginStorage(root: root, pluginID: "test.store")
        #expect(await reopened.value(forKey: "greeting") == .string("hi"))
        #expect(try await reopened.decode(Settings.self, forKey: "settings") == Settings(interval: 25, labels: ["a", "b"]))
        await reopened.set(nil, forKey: "greeting")
        try await reopened.flush()
        #expect(await PluginStorage(root: root, pluginID: "test.store").value(forKey: "greeting") == nil)
    }

    @Test func writesAtomicallyWithoutLeftovers() async throws {
        let root = temporaryDirectory()
        let storage = PluginStorage(root: root, pluginID: "test.atomic")
        for round in 0..<5 {
            await storage.set(.number(Double(round)), forKey: "round")
            try await storage.flush()
        }
        let directory = storage.url.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["test.atomic.json"])
        let object = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: storage.url))
        #expect(object["round"] == .number(4))
    }

    @Test func debouncesBurstsIntoOneWrite() async throws {
        let storage = PluginStorage(root: temporaryDirectory(), pluginID: "test.debounce", debounce: .milliseconds(100))
        for value in 0..<20 {
            await storage.set(.number(Double(value)), forKey: "value")
        }
        #expect(!FileManager.default.fileExists(atPath: storage.url.path))
        #expect(await storage.writeCount == 0)

        var waited = 0
        while await storage.writeCount == 0, waited < 50 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(await storage.writeCount == 1)
        let object = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: storage.url))
        #expect(object["value"] == .number(19))
        // Nothing pending: flush does not write again.
        try await storage.flush()
        #expect(await storage.writeCount == 1)
    }

    @Test func corruptFileIsMovedAsideAndStartsEmpty() async throws {
        let root = temporaryDirectory()
        let storage = PluginStorage(root: root, pluginID: "test.corrupt")
        try FileManager.default.createDirectory(at: storage.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: storage.url)
        #expect(await storage.allValues.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: storage.url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("test.corrupt.json.corrupt-") })
    }

    @MainActor
    @Test func hostFlushesStorageOnDisable() async throws {
        let root = temporaryDirectory()
        let host = PluginHost(plugins: [StoringPlugin.self], dataRoot: root, storageDebounce: .seconds(60))
        await host.load()
        #expect(host.record(for: "test.storing")?.state == .active)
        // Let the plugin's fire-and-forget write reach its storage actor.
        try await Task.sleep(for: .milliseconds(100))
        try await host.setEnabled(false, for: "test.storing")
        let reopened = PluginStorage(root: root, pluginID: "test.storing")
        #expect(await reopened.value(forKey: "seen") == .bool(true))
    }
}

private final class StoringPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.storing", version: "1.0.0", name: "Storing", capabilities: [.storage])
    func activate(context: PluginContext) throws {
        let storage = try context.storage()
        Task { await storage.set(.bool(true), forKey: "seen") }
    }
}
