import Foundation
import Testing
@testable import AletheFoundation

/// The event as upstream would serialize it (`EventBusPayload`).
private func upstreamJSON(_ event: BusEvent) throws -> [String: Any] {
    let data = try JSONEncoder().encode(event)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func dataKeys(_ event: BusEvent) -> Set<String> {
    Set(event.data.objectValue?.keys.map { $0 } ?? [])
}

@Suite("Published events (P6-19)")
struct PublishedEventsTests {
    // MARK: Merge Center

    @Test func mergeAnalysisIsCleanOrConflict() throws {
        let clean = BusEvent.mergeAnalyzed(projectID: "p1", source: "feature", target: "main", clean: true,
                                           conflictCount: 0, classes: [])
        #expect(clean.type == "MergeClean")
        #expect(clean.taskID == "p1")
        #expect(clean.agentID == nil)
        #expect(clean.correlationID.hasPrefix("merge-"))
        #expect(dataKeys(clean) == ["source", "target", "conflict_count", "classes"])

        let conflict = BusEvent.mergeAnalyzed(projectID: nil, source: "feature", target: "main", clean: false,
                                              conflictCount: 2, classes: ["Code", "Lockfile"])
        #expect(conflict.type == "MergeConflict")
        let json = try upstreamJSON(conflict)
        #expect(json["event_type"] as? String == "MergeConflict")
        #expect(json["task_id"] is NSNull)
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["conflict_count"] as? Int == 2)
        #expect(data["classes"] as? [String] == ["Code", "Lockfile"])
        #expect(data["source"] as? String == "feature")
        #expect(data["target"] as? String == "main")
    }

    @Test func preparedMergeRequestsThenReportsConflicts() {
        let clean = BusEvent.mergePrepared(environmentID: "abc123", projectID: "p1", source: "f", target: "main",
                                           clean: true, conflictCount: 0, environmentPath: "/r/.alethe/merge-envs/abc123")
        #expect(clean.map(\.type) == ["MergeRequested"])
        #expect(clean[0].correlationID == "merge-abc123")
        #expect(clean[0].data.objectValue?["clean"] == .bool(true))
        #expect(dataKeys(clean[0]) == ["source", "target", "clean"])

        let conflicted = BusEvent.mergePrepared(environmentID: "abc123", projectID: "p1", source: "f", target: "main",
                                                clean: false, conflictCount: 3, environmentPath: "/r/env")
        #expect(conflicted.map(\.type) == ["MergeRequested", "MergeConflict"])
        #expect(conflicted.allSatisfy { $0.correlationID == "merge-abc123" && $0.taskID == "p1" })
        #expect(conflicted[1].data == .object(["conflict_count": .number(3), "env": .string("/r/env")]))
    }

    @Test func validationPassesOrNamesTheFailingCommand() {
        let passed = BusEvent.mergeValidation(environmentID: "e1", projectID: "p1", failedStage: nil)
        #expect(passed.type == "MergeValidated")
        #expect(passed.data == .object([:]))
        #expect(passed.correlationID == "merge-e1")

        let failed = BusEvent.mergeValidation(environmentID: "e1", projectID: "p1", failedStage: "swift test")
        #expect(failed.type == "MergeValidationFailed")
        #expect(failed.data == .object(["stage": .string("swift test")]))
    }

    @Test func mergedAndAbortedCarryUpstreamData() {
        let merged = BusEvent.mergeMerged(environmentID: "e1", projectID: "p1", source: "f", target: "main")
        #expect(merged.type == "MergeMerged")
        #expect(merged.data == .object(["source": .string("f"), "target": .string("main")]))
        let aborted = BusEvent.mergeAborted(environmentID: "e1", projectID: nil)
        #expect(aborted.type == "MergeAborted")
        #expect(aborted.correlationID == "merge-e1")
        #expect(aborted.data == .object([:]))
    }

    // MARK: Graphify

    @Test func graphGenerationAndRollbackAreGraphUpdated() throws {
        let generated = BusEvent.graphGenerated(repository: "/repo")
        #expect(generated.type == "GraphUpdated")
        #expect(generated.correlationID.hasPrefix("graphify-"))
        #expect(generated.taskID == nil)
        #expect(generated.data == .object(["action": .string("bootstrap"), "repo": .string("/repo")]))

        let rolledBack = BusEvent.graphRolledBack(snapshotID: "1700000000000", projectID: "p1")
        #expect(rolledBack.type == "GraphUpdated")
        #expect(rolledBack.taskID == "p1")
        #expect(rolledBack.data == .object(["action": .string("rollback"), "snapshot_id": .string("1700000000000")]))
    }

    // MARK: Plugins

    @Test func pluginEventsAreKeyedByPlugin() {
        let enabled = BusEvent.pluginEnabledChanged(id: "alethe.todos", enabled: true)
        #expect(enabled.type == "PluginEnabled")
        #expect(enabled.correlationID == "plugin-alethe.todos")
        #expect(enabled.data == .object(["id": .string("alethe.todos"), "enabled": .bool(true)]))
        #expect(BusEvent.pluginEnabledChanged(id: "x", enabled: false).type == "PluginDisabled")

        let failed = BusEvent.pluginFailed(id: "x", error: "incompatibleAPI")
        #expect(failed.type == "PluginFailed")
        #expect(failed.correlationID == "plugin-x")
        #expect(failed.data == .object(["id": .string("x"), "error": .string("incompatibleAPI")]))
    }

    // MARK: Resources

    @Test func resourceMetricsHaveUpstreamKeys() throws {
        let event = BusEvent.resourceMetrics(memoryPressure: "Ok", systemAvailableMB: 4096, systemTotalMB: 16384,
                                             appMB: 210.5, ptysMB: 512, processCount: 7, policyTriggerCount: 2)
        #expect(event.type == "ResourceMetricsUpdated")
        #expect(event.correlationID == "resource-manager")
        #expect(event.taskID == nil)
        #expect(dataKeys(event) == ["memory_pressure", "system_available_mb", "system_total_mb", "app_mb",
                                    "webview_mb", "ptys_mb", "process_count", "policy_trigger_count"])
        let data = try #require(try upstreamJSON(event)["data"] as? [String: Any])
        #expect(data["memory_pressure"] as? String == "Ok")
        #expect(data["process_count"] as? Int == 7)
        #expect(data["policy_trigger_count"] as? Int == 2)
        #expect(data["webview_mb"] as? Double == 0)
    }
}

@MainActor
@Suite("Event outbox")
struct EventOutboxTests {
    @Test func publishesStraightToAnAttachedBusInOrder() async {
        let bus = EventBus()
        let stream = await bus.subscribe()
        let outbox = EventOutbox(bus: bus)
        for name in ["A", "B", "C"] { outbox.publish(BusEvent(type: name, correlationID: "c")) }
        await outbox.drained()
        await bus.finishAll()
        var types: [String] = []
        for await event in stream { types.append(event.type) }
        #expect(types == ["A", "B", "C"])
    }

    @Test func holdsEventsUntilABusIsAttached() async {
        let outbox = EventOutbox(limit: 2)
        outbox.publish([BusEvent(type: "A", correlationID: "c"), BusEvent(type: "B", correlationID: "c"),
                        BusEvent(type: "C", correlationID: "c")])
        #expect(outbox.pending.map(\.type) == ["B", "C"])

        let bus = EventBus()
        let stream = await bus.subscribe()
        outbox.attach(bus)
        #expect(outbox.pending.isEmpty)
        outbox.attach(bus)
        outbox.publish(BusEvent(type: "D", correlationID: "c"))
        await outbox.drained()
        await bus.finishAll()
        var types: [String] = []
        for await event in stream { types.append(event.type) }
        #expect(types == ["B", "C", "D"])
    }
}
