import Foundation
import Testing
import AletheExtensionSDK
import AlethePluginKit
@testable import AletheExtensionHost

private let bundleID = "dev.example.Sample.sidebar"

private func manifest(_ caps: [String], version: String = "1.0") throws -> PluginManifest {
    try ExtensionCapabilityMapper.manifest(for: ExtensionDescriptor(
        bundleIdentifier: bundleID,
        payload: ExtensionManifestPayload(name: "Sample", version: version, capabilities: caps)
    ))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "alethe-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite struct ExtensionPayloadTests {
    @Test func descriptorFromPayload() {
        let payload = ExtensionManifestPayload(
            name: "Sample", version: "2.1", apiMajor: 1, apiMinor: 0, capabilities: ["storage"],
            commands: [.init(id: "sample.hello", title: "Hello")],
            sidebarTab: .init(title: "Sample", symbol: "star")
        )
        let descriptor = ExtensionDescriptor(bundleIdentifier: bundleID, payload: payload)
        #expect(descriptor.localizedName == "Sample")
        #expect(descriptor.version == "2.1")
        #expect(descriptor.declaredCapabilities == ["storage"])
        #expect(descriptor.apiVersion == PluginAPIVersion(major: 1, minor: 0))
    }

    @Test func wireRoundTrips() {
        let payload = ExtensionManifestPayload(name: "S", version: "1", capabilities: [], commands: [.init(id: "a", title: "A")])
        #expect(ExtensionWire.decode(ExtensionManifestPayload.self, from: ExtensionWire.encode(payload)) == payload)
        let request = HostRequest.storageSet(key: "k", value: nil)
        #expect(ExtensionWire.decode(HostRequest.self, from: ExtensionWire.encode(request)) == request)
        #expect(ExtensionWire.decode(HostResponse.self, from: Data("junk".utf8)) == nil)
    }
}

@Suite struct ExtensionHostStateTests {
    @Test func firstEnableNeedsConsentThenActivates() throws {
        let m = try manifest(["storage"])
        var state = ExtensionHostState()
        #expect(state.requestEnable(m) == .needsConsent([.storage]))
        #expect(!state.isActive(m))
        state.approve(m)
        #expect(state.isActive(m))
        #expect(state.isAllowed(.storage, for: m.id))
    }

    @Test func reEnableAfterDisableSkipsThePrompt() throws {
        let m = try manifest(["storage"])
        var state = ExtensionHostState()
        state.approve(m)
        state.disable(m.id)
        #expect(!state.isAllowed(.storage, for: m.id), "a disabled extension gets no services")
        #expect(state.requestEnable(m) == .enabled)
        #expect(state.isActive(m))
    }

    @Test func updateAskingForMorePausesUntilReviewed() throws {
        var state = ExtensionHostState()
        state.approve(try manifest(["storage"]))
        let updated = try manifest(["storage", "network"], version: "1.1")
        #expect(!state.isActive(updated))
        #expect(state.requestEnable(updated) == .needsConsent([.network]))
        state.approve(updated)
        #expect(state.isActive(updated))
    }

    @Test func declineKeepsItOffAndAsksAgainForEverything() throws {
        let m = try manifest(["storage", "git"])
        var state = ExtensionHostState()
        state.decline(m)
        #expect(!state.isActive(m))
        #expect(state.requestEnable(m) == .needsConsent([.storage, .git]))
    }

    @Test func persistsAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "extensions.json")
        var state = ExtensionHostState()
        state.approve(try manifest(["storage"]), at: Date(timeIntervalSince1970: 0))
        try state.save(to: url)
        #expect(ExtensionHostState.load(from: url) == state)
        try Data("{".utf8).write(to: url)
        #expect(ExtensionHostState.load(from: url) == ExtensionHostState())
    }
}

@Suite struct ExtensionRequestRouterTests {
    @Test func storageRoundTripWhenGranted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PluginStorage(root: directory, pluginID: ExtensionRequestRouter.storageID(for: bundleID))
        let set = await ExtensionRequestRouter.handle(.storageSet(key: "count", value: "3"), isAllowed: { _ in true }, storage: storage)
        #expect(set == .done)
        let get = await ExtensionRequestRouter.handle(.storageGet(key: "count"), isAllowed: { _ in true }, storage: storage)
        #expect(get == .value("3"))
        let missing = await ExtensionRequestRouter.handle(.storageGet(key: "other"), isAllowed: { _ in true }, storage: storage)
        #expect(missing == .value(nil))
    }

    @Test func deniedWithoutTheCapability() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PluginStorage(root: directory, pluginID: "ext.x")
        let response = await ExtensionRequestRouter.handle(.storageSet(key: "k", value: "v"), isAllowed: { $0 != .storage }, storage: storage)
        #expect(response == .denied(capability: "storage"))
        #expect(await storage.value(forKey: "k") == nil)
    }

    @Test func storageIDIsAValidPluginID() {
        let id = ExtensionRequestRouter.storageID(for: bundleID)
        #expect(PluginManifest(id: id, version: "1", name: "x").hasValidID)
    }
}
