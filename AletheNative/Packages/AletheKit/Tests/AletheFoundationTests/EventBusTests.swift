import Foundation
import Testing
@testable import AletheFoundation

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "alethe-telemetry-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite("Event bus")
struct EventBusTests {
    /// Upstream `event_bus.rs` `test_event_bus_publish_subscribe`.
    @Test func eventBusPublishSubscribe() async {
        let bus = EventBus()
        let stream = await bus.subscribe()
        await bus.publish(BusEvent(type: "TestEvent", timestampMS: 123_456_789, correlationID: "test-corr-id",
                                   data: .object(["foo": .string("bar")])))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.type == "TestEvent")
        #expect(received?.correlationID == "test-corr-id")
        #expect(received?.data.objectValue?["foo"] == .string("bar"))
    }

    @Test func everySubscriberGetsEachEvent() async {
        let bus = EventBus()
        let first = await bus.subscribe()
        let second = await bus.subscribe()
        await bus.publish("A", correlationID: "c")
        await bus.finishAll()
        var firstTypes: [String] = []
        for await event in first { firstTypes.append(event.type) }
        var secondTypes: [String] = []
        for await event in second { secondTypes.append(event.type) }
        #expect(firstTypes == ["A"])
        #expect(secondTypes == ["A"])
    }

    @Test func aSlowSubscriberLosesItsOldestEvents() async {
        let bus = EventBus()
        let stream = await bus.subscribe(bufferLimit: 3)
        for index in 0..<10 { await bus.publish("E\(index)", correlationID: "c") }
        await bus.finishAll()
        var types: [String] = []
        for await event in stream { types.append(event.type) }
        #expect(types == ["E7", "E8", "E9"])
    }

    @Test func aFinishedConsumerIsUnsubscribed() async throws {
        let bus = EventBus()
        let consumer = Task {
            for await _ in await bus.subscribe() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await bus.subscriberCount == 1)
        consumer.cancel()
        for _ in 0..<100 where await bus.subscriberCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await bus.subscriberCount == 0)
    }

    @Test func encodesUpstreamKeys() throws {
        let event = BusEvent(type: "PlanningUpdated", timestampMS: 1000, correlationID: "gsd-x", taskID: "p1",
                             data: .object(["planning_dir": .string("/r/.planning")]))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(Set(object.keys) == ["event_type", "timestamp_ms", "correlation_id", "task_id", "agent_id", "data"])
        #expect(object["agent_id"] is NSNull)
        #expect(object["task_id"] as? String == "p1")
        let decoded = try JSONDecoder().decode(BusEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }

    @Test func correlationIDsCarryThePrefix() {
        let id = BusEvent.correlationID(prefix: "gsd")
        #expect(id.hasPrefix("gsd-"))
        #expect(id.count == 25)
        #expect(id != BusEvent.correlationID(prefix: "gsd"))
    }
}

@Suite("Telemetry")
struct TelemetryTests {
    /// Upstream `telemetry.rs` `test_telemetry_metrics_and_traces`.
    @Test func telemetryMetricsAndTraces() async throws {
        let telemetry = Telemetry()
        let first = BusEvent(type: "TaskStarted", timestampMS: 1000, correlationID: "corr-123", taskID: "task-1",
                             data: .object(["memory_mb": .number(150.0)]))
        let second = BusEvent(type: "TaskFinished", timestampMS: 2000, correlationID: "corr-123", taskID: "task-1",
                              data: .object(["duration_ms": .number(1000.0), "cost_usd": .number(0.05)]))
        await telemetry.record(first)
        await telemetry.record(second)

        let metrics = await telemetry.metrics()
        #expect(metrics["alethe_event_taskstarted"]?.count == 1)
        #expect(metrics["alethe_event_taskfinished"]?.count == 1)
        #expect(metrics["alethe_metric_memory_mb"]?.lastValue == 150.0)
        #expect(metrics["alethe_metric_duration_ms"]?.lastValue == 1000.0)
        #expect(metrics["alethe_metric_cost_usd"]?.lastValue == 0.05)

        #expect(await telemetry.traces().count >= 2)
        let specific = await telemetry.traces(correlationID: "corr-123")
        #expect(specific.count == 2)
        #expect(specific.first?.type == "TaskStarted")
        #expect(specific.last?.type == "TaskFinished")
    }

    @Test func metricsSumAndIgnoreOtherFields() async {
        let telemetry = Telemetry()
        await telemetry.record(BusEvent(type: "Run", timestampMS: 1, correlationID: "a",
                                        data: .object(["duration_ms": .number(10), "tokens": .number(99)])))
        await telemetry.record(BusEvent(type: "run", timestampMS: 2, correlationID: "a",
                                        data: .object(["duration_ms": .number(30), "cost_usd": .string("1")])))
        let metrics = await telemetry.metrics()
        #expect(metrics["alethe_event_run"] == MetricData(count: 2))
        #expect(metrics["alethe_metric_duration_ms"] == MetricData(count: 2, lastValue: 30, sum: 40))
        #expect(metrics["alethe_metric_tokens"] == nil)
        #expect(metrics["alethe_metric_cost_usd"] == nil)
    }

    @Test func keepsTheLastTracesOnly() async {
        let telemetry = Telemetry()
        for index in 0..<(Telemetry.traceLimit + 20) {
            await telemetry.record(BusEvent(type: "E", timestampMS: UInt64(index), correlationID: "c\(index % 2)"))
        }
        let traces = await telemetry.traces()
        #expect(traces.count == Telemetry.traceLimit)
        #expect(traces.first?.timestampMS == 20)
        #expect(traces.last?.timestampMS == UInt64(Telemetry.traceLimit + 19))
    }

    @Test func filtersByCorrelationID() async {
        let telemetry = Telemetry()
        await telemetry.record(BusEvent(type: "A", timestampMS: 1, correlationID: "x"))
        await telemetry.record(BusEvent(type: "B", timestampMS: 2, correlationID: "y"))
        await telemetry.record(BusEvent(type: "C", timestampMS: 3, correlationID: "x"))
        #expect(await telemetry.traces(correlationID: "x").map(\.type) == ["A", "C"])
        #expect(await telemetry.traces(correlationID: "z").isEmpty)
        #expect(await telemetry.traces().map(\.type) == ["A", "B", "C"])
    }

    @Test func fileLinesAreRedactedJSON() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv"
        let telemetry = Telemetry(logsDirectory: directory)
        await telemetry.record(BusEvent(type: "AgentSpawned", timestampMS: 5, correlationID: "c",
                                        data: .object(["api_key": .string(secret), "note": .string("key \(secret)")])))
        let text = try String(contentsOf: directory.appending(path: Telemetry.fileName), encoding: .utf8)
        #expect(!text.contains(secret))
        #expect(text.contains(SecretRedactor.placeholder))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        let decoded = try JSONDecoder().decode(BusEvent.self, from: Data(lines[0].utf8))
        #expect(decoded.type == "AgentSpawned")
    }

    @Test func followsTheBus() async throws {
        let bus = EventBus()
        let telemetry = Telemetry()
        let task = await telemetry.follow(bus)
        await bus.publish("PlanningUpdated", correlationID: "gsd-1")
        await bus.finishAll()
        await task.value
        #expect(await telemetry.metrics()["alethe_event_planningupdated"]?.count == 1)
    }
}
