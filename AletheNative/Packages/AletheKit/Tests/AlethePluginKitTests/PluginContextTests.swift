import Foundation
import Testing
@testable import AlethePluginKit

@MainActor
private func makeContext(_ capabilities: Set<PluginCapability>, services: PluginServices = PluginServices()) -> PluginContext {
    let manifest = PluginManifest(id: "test.context", version: "1.0.0", name: "Context", capabilities: capabilities)
    let storage = PluginStorage(root: temporaryDirectory(), pluginID: manifest.id)
    return PluginContext(manifest: manifest, services: services) { storage }
}

private let allServices = PluginServices(
    runGit: { arguments, _ in arguments.joined(separator: " ") },
    readFile: { _ in Data("hello".utf8) },
    writeFile: { _, _ in },
    sendTerminalInput: { _, _ in },
    urlSession: .shared
)

@MainActor
@Suite struct PluginContextTests {
    @Test func undeclaredCapabilitiesThrow() async {
        let context = makeContext([], services: allServices)
        let url = URL(filePath: "/tmp/x")
        #expect(throws: PluginError.undeclaredCapability(.storage, pluginID: "test.context")) { try context.storage() }
        #expect(throws: PluginError.undeclaredCapability(.network, pluginID: "test.context")) { try context.urlSession() }
        await #expect(throws: PluginError.undeclaredCapability(.git, pluginID: "test.context")) {
            try await context.runGit(["status"], in: url)
        }
        await #expect(throws: PluginError.undeclaredCapability(.filesystemRead, pluginID: "test.context")) {
            try await context.readFile(at: url)
        }
        await #expect(throws: PluginError.undeclaredCapability(.filesystemWrite, pluginID: "test.context")) {
            try await context.writeFile(Data(), to: url)
        }
        await #expect(throws: PluginError.undeclaredCapability(.terminalInput, pluginID: "test.context")) {
            try await context.sendTerminalInput("ls\n", toTerminal: "t1")
        }
    }

    @Test func declaredCapabilitiesReachTheServices() async throws {
        let context = makeContext(Set(PluginCapability.allCases), services: allServices)
        let url = URL(filePath: "/tmp/x")
        #expect(try await context.runGit(["log", "-1"], in: url) == "log -1")
        #expect(try await context.readFile(at: url) == Data("hello".utf8))
        try await context.writeFile(Data(), to: url)
        try await context.sendTerminalInput("ls\n", toTerminal: "t1")
        _ = try context.urlSession()
        _ = try context.storage()
    }

    @Test func declaredButMissingServiceIsReported() async {
        let context = makeContext([.git, .filesystemWrite])
        // Declaring a capability does not imply another one.
        await #expect(throws: PluginError.undeclaredCapability(.filesystemRead, pluginID: "test.context")) {
            try await context.readFile(at: URL(filePath: "/tmp/x"))
        }
        await #expect(throws: PluginError.serviceUnavailable(.git)) {
            try await context.runGit([], in: URL(filePath: "/tmp"))
        }
    }

    @Test func inactiveContextRefusesEverything() {
        let context = makeContext([.storage])
        context.isActive = false
        #expect(throws: PluginError.inactive(pluginID: "test.context")) { try context.storage() }
        #expect(throws: PluginError.inactive(pluginID: "test.context")) {
            try context.addSheet(SheetContribution(id: "s", title: "S", viewID: "v"))
        }
    }

    @Test func duplicateContributionIDsThrow() throws {
        let context = makeContext([])
        let provider = AgentProviderContribution(id: "agent.x", name: "X", command: "x")
        try context.addAgentProvider(provider)
        #expect(throws: PluginError.duplicateContribution(kind: "agentProvider", id: "agent.x")) {
            try context.addAgentProvider(provider)
        }
        #expect(context.contributions.agentProviders.count == 1)
    }
}
