import AletheFoundation
import Foundation
import Testing
@testable import AletheIntegrations

private func writer(_ root: URL) -> ConfigFileWriter {
    ConfigFileWriter(backupRoot: root.appending(path: ".test-profile/config-backups"))
}

private func read(_ root: URL, _ relativePath: String) throws -> String {
    try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
}

private func json(_ root: URL, _ relativePath: String) throws -> OrderedJSONObject {
    try #require(try OrderedJSON.parse(read(root, relativePath)).objectValue)
}

@discardableResult
private func install(_ root: URL, _ chain: [String] = []) throws -> GSDPluginInstallReport {
    try GSDOpenCodePlugin.install(root: root, modelChain: chain, writer: writer(root))
}

// Upstream `opencode_gsd_plugin.rs` tests.
@Suite struct GSDOpenCodePluginTests {
    @Test func bundledPluginIsTheManagedUpstreamAsset() throws {
        let source = try GSDOpenCodePlugin.bundledPlugin()
        #expect(source.hasPrefix("// alethe-managed: v12"))
        #expect(GSDOpenCodePlugin.managedVersion(of: source) == 12)
    }

    @Test func pluginIsWrittenWhenAbsent() throws {
        let root = makeCheckout("write-absent")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try install(root)
        #expect(report.plugin == .written)
        #expect(try read(root, GSDOpenCodePlugin.pluginRelativePath) == GSDOpenCodePlugin.bundledPlugin())
        #expect(try install(root).plugin == .unchanged)
    }

    @Test func entryIsMergedWithoutClobberingTheConfig() throws {
        let root = makeCheckout("merge-no-clobber")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, "opencode.json", #"{"model": "some/model", "plugin": ["./other-plugin.ts"]}"#)
        let report = try install(root)
        let config = try json(root, "opencode.json")
        #expect(config["model"] == .string("some/model"))
        #expect(config["plugin"] == .array([.string("./other-plugin.ts"), .string(GSDOpenCodePlugin.configEntry)]))
        #expect(config.keys == ["model", "plugin"])
        #expect(report.openCodeConfig == .written)
        #expect(report.configBackup != nil)
    }

    @Test func entryIsNotDuplicatedOnASecondInstall() throws {
        let root = makeCheckout("no-duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        try install(root)
        let before = try read(root, "opencode.json")
        let second = try install(root)
        #expect(second.openCodeConfig == .unchanged)
        #expect(try read(root, "opencode.json") == before)
        let plugins = try #require(try json(root, "opencode.json")["plugin"]?.arrayValue)
        #expect(plugins.filter { $0 == .string(GSDOpenCodePlugin.configEntry) }.count == 1)
    }

    @Test func aUserEditedPluginIsKept() throws {
        let root = makeCheckout("no-overwrite-edited")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, GSDOpenCodePlugin.pluginRelativePath, "// custom user content, no marker\n")
        #expect(try install(root).plugin == .skipped)
        #expect(try read(root, GSDOpenCodePlugin.pluginRelativePath) == "// custom user content, no marker\n")
    }

    @Test func aNewerAlethesPluginIsKept() throws {
        let root = makeCheckout("no-overwrite-future")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, GSDOpenCodePlugin.pluginRelativePath, "// alethe-managed: v99\ncustom future content\n")
        try install(root)
        #expect(try read(root, GSDOpenCodePlugin.pluginRelativePath).hasPrefix("// alethe-managed: v99"))
    }

    @Test func anOlderManagedPluginIsUpdated() throws {
        let root = makeCheckout("auto-update")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, GSDOpenCodePlugin.pluginRelativePath, "// alethe-managed: v1\nold body\n")
        #expect(try install(root).plugin == .written)
        #expect(try read(root, GSDOpenCodePlugin.pluginRelativePath) == GSDOpenCodePlugin.bundledPlugin())
    }

    @Test func configIsCreatedWithTheSchema() throws {
        let root = makeCheckout("create-scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try install(root)
        let config = try json(root, "opencode.json")
        #expect(config["$schema"] == .string("https://opencode.ai/config.json"))
        #expect(config["plugin"] == .array([.string(GSDOpenCodePlugin.configEntry)]))
        #expect(report.configBackup == nil)
    }

    @Test func modelChainIsRewrittenOnEveryInstall() throws {
        let root = makeCheckout("model-chain")
        defer { try? FileManager.default.removeItem(at: root) }
        try install(root, ["mimo-v2.5-free", "laguna-s-2.1-free"])
        #expect(try json(root, GSDOpenCodePlugin.modelChainRelativePath)["modelChain"]
            == .array([.string("mimo-v2.5-free"), .string("laguna-s-2.1-free")]))
        #expect(try install(root, ["mimo-v2.5-free", "laguna-s-2.1-free"]).modelChain == .unchanged)
        #expect(try install(root).modelChain == .written)
        #expect(try json(root, GSDOpenCodePlugin.modelChainRelativePath)["modelChain"] == .array([]))
    }

    @Test func anUnparsableConfigIsLeftAlone() throws {
        let root = makeCheckout("unparsable")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, "opencode.json", "{ // a comment\n \"model\": 1 }")
        #expect(try install(root).openCodeConfig == .skipped)
        #expect(try read(root, "opencode.json") == "{ // a comment\n \"model\": 1 }")
    }

    @Test func aPluginKeyThatIsNotAListIsLeftAlone() throws {
        let root = makeCheckout("plugin-not-list")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, "opencode.json", #"{"plugin": "./one.ts"}"#)
        #expect(try install(root).openCodeConfig == .skipped)
        #expect(try read(root, "opencode.json") == #"{"plugin": "./one.ts"}"#)
    }

    @Test func writeDecisionFollowsTheMarker() {
        #expect(GSDOpenCodePlugin.shouldWritePlugin(existing: nil, bundledVersion: 12))
        #expect(GSDOpenCodePlugin.shouldWritePlugin(existing: "// alethe-managed: v12\n", bundledVersion: 12))
        #expect(GSDOpenCodePlugin.shouldWritePlugin(existing: "// alethe-managed: v3\n", bundledVersion: 12))
        #expect(!GSDOpenCodePlugin.shouldWritePlugin(existing: "// alethe-managed: v13\n", bundledVersion: 12))
        #expect(!GSDOpenCodePlugin.shouldWritePlugin(existing: "// alethe-managed: vX\n", bundledVersion: 12))
        #expect(!GSDOpenCodePlugin.shouldWritePlugin(existing: "\n// alethe-managed: v1\n", bundledVersion: 12))
    }
}
