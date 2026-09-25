import Foundation
import Testing
import AlethePluginKit
@testable import AletheExtensionHost

private func descriptor(_ caps: [String], version: String = "1.0", api: PluginAPIVersion = .current) -> ExtensionDescriptor {
    ExtensionDescriptor(
        bundleIdentifier: "dev.example.sample.ext",
        localizedName: "Sample",
        version: version,
        declaredCapabilities: caps,
        apiVersion: api
    )
}

@Suite struct ExtensionCapabilityMapperTests {
    @Test func mapsKnownCapabilities() throws {
        let caps = try ExtensionCapabilityMapper.capabilities(of: descriptor(["storage", "git", "storage"]))
        #expect(caps == [.storage, .git])
    }

    @Test func rejectsUnknownCapabilities() {
        #expect(throws: ExtensionValidationError.unknownCapabilities(["kernel", "rootShell"])) {
            try ExtensionCapabilityMapper.capabilities(of: descriptor(["storage", "rootShell", "kernel"]))
        }
    }

    @Test func rejectsIncompatibleAPI() {
        let api = PluginAPIVersion(major: 2)
        #expect(throws: ExtensionValidationError.incompatibleAPI(api)) {
            try ExtensionCapabilityMapper.manifest(for: descriptor([], api: api))
        }
    }

    @Test func manifestStartsDisabled() throws {
        let manifest = try ExtensionCapabilityMapper.manifest(for: descriptor(["network"]))
        #expect(manifest.id == "dev.example.sample.ext")
        #expect(manifest.enabledByDefault == false)
        #expect(manifest.capabilities == [.network])
    }
}

@Suite struct ExtensionConsentLedgerTests {
    @Test func firstEnablePromptsForAllCapabilities() throws {
        let manifest = try ExtensionCapabilityMapper.manifest(for: descriptor(["storage", "git"]))
        #expect(ExtensionConsentLedger().decision(for: manifest) == .promptRequired([.storage, .git]))
    }

    @Test func firstEnablePromptsEvenWithoutCapabilities() throws {
        let manifest = try ExtensionCapabilityMapper.manifest(for: descriptor([]))
        #expect(ExtensionConsentLedger().decision(for: manifest) == .promptRequired([]))
    }

    @Test func grantAllowsAndEnforces() throws {
        let manifest = try ExtensionCapabilityMapper.manifest(for: descriptor(["storage"]))
        var ledger = ExtensionConsentLedger()
        ledger.grant(manifest)
        #expect(ledger.decision(for: manifest) == .allowed)
        #expect(ledger.isAllowed(.storage, for: manifest.id))
        #expect(!ledger.isAllowed(.terminalInput, for: manifest.id))
    }

    @Test func updateRequestingMoreRePromptsForDelta() throws {
        var ledger = ExtensionConsentLedger()
        ledger.grant(try ExtensionCapabilityMapper.manifest(for: descriptor(["storage"])))
        let updated = try ExtensionCapabilityMapper.manifest(for: descriptor(["storage", "network"], version: "1.1"))
        #expect(ledger.decision(for: updated) == .promptRequired([.network]))
        #expect(!ledger.isAllowed(.network, for: updated.id))
    }

    @Test func denyAndForget() throws {
        let manifest = try ExtensionCapabilityMapper.manifest(for: descriptor(["storage"]))
        var ledger = ExtensionConsentLedger()
        ledger.grant(manifest)
        ledger.deny(manifest)
        #expect(ledger.decision(for: manifest) == .denied)
        #expect(!ledger.isAllowed(.storage, for: manifest.id))
        ledger.forget(manifest.id)
        #expect(ledger.decision(for: manifest) == .promptRequired([.storage]))
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = ExtensionConsentLedger()
        ledger.grant(try ExtensionCapabilityMapper.manifest(for: descriptor(["git"])), at: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(ExtensionConsentLedger.self, from: data) == ledger)
    }
}
