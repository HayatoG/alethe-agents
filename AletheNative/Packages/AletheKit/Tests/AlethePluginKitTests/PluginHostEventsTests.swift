import Foundation
import Testing
@testable import AletheFoundation
@testable import AlethePluginKit

private struct EventsBoom: Error {}

private final class QuietPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "events.quiet", version: "1.0.0", name: "Quiet")
    func activate(context: PluginContext) throws {}
}

private final class ThrowingPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "events.throwing", version: "1.0.0", name: "Throwing")
    func activate(context: PluginContext) throws { throw EventsBoom() }
}

/// Plugin events for the bus (P6-19).
@MainActor
@Suite struct PluginHostEventsTests {
    @Test func aLoadFailureIsHeldUntilABusIsAttached() async {
        let host = PluginHost(plugins: [QuietPlugin.self, ThrowingPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        #expect(host.events.pending.map(\.type) == ["PluginFailed"])
        let failure = host.events.pending[0]
        #expect(failure.correlationID == "plugin-events.throwing")
        #expect(failure.data.objectValue?["id"] == .string("events.throwing"))
        guard case .string(let error)? = failure.data.objectValue?["error"] else {
            Issue.record("no error"); return
        }
        #expect(error.contains("EventsBoom"))

        let bus = EventBus()
        let stream = await bus.subscribe()
        host.events.attach(bus)
        await host.events.drained()
        await bus.finishAll()
        var types: [String] = []
        for await event in stream { types.append(event.type) }
        #expect(types == ["PluginFailed"])
    }

    @Test func togglingPublishesEnabledAndDisabled() async throws {
        let host = PluginHost(plugins: [QuietPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        #expect(host.events.pending.isEmpty)
        try await host.setEnabled(false, for: "events.quiet")
        try await host.setEnabled(true, for: "events.quiet")
        #expect(host.events.pending.map(\.type) == ["PluginDisabled", "PluginEnabled"])
        #expect(host.events.pending.map(\.data) == [
            .object(["id": .string("events.quiet"), "enabled": .bool(false)]),
            .object(["id": .string("events.quiet"), "enabled": .bool(true)]),
        ])
    }

    @Test func reEnablingAFailingPluginReportsTheFailureAgain() async throws {
        let host = PluginHost(plugins: [ThrowingPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        try await host.setEnabled(true, for: "events.throwing")
        #expect(host.events.pending.map(\.type) == ["PluginFailed", "PluginEnabled", "PluginFailed"])
    }
}
