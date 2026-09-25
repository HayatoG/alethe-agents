import Foundation

/// One event on the bus (upstream `EventBusPayload`), encoded with upstream's snake_case keys so
/// `telemetry.jsonl` lines and exported traces keep upstream's shape.
public struct BusEvent: Codable, Equatable, Hashable, Sendable {
    public var type: String
    /// Milliseconds since 1970.
    public var timestampMS: UInt64
    public var correlationID: String
    public var taskID: String?
    public var agentID: String?
    public var data: JSONValue

    public init(type: String, timestampMS: UInt64, correlationID: String, taskID: String? = nil,
                agentID: String? = nil, data: JSONValue = .object([:])) {
        self.type = type
        self.timestampMS = timestampMS
        self.correlationID = correlationID
        self.taskID = taskID
        self.agentID = agentID
        self.data = data
    }

    /// An event stamped now (upstream `publish_event_simple`).
    public init(type: String, correlationID: String, taskID: String? = nil, agentID: String? = nil,
                data: JSONValue = .object([:]), date: Date = .now) {
        self.init(type: type, timestampMS: UInt64(max(0, date.timeIntervalSince1970 * 1000)),
                  correlationID: correlationID, taskID: taskID, agentID: agentID, data: data)
    }

    public var date: Date { Date(timeIntervalSince1970: Double(timestampMS) / 1000) }

    /// A fresh correlation id, `<prefix>-<random>` (upstream `format!("gsd-{}", nanoid!())`).
    public static func correlationID(prefix: String) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-")
        var generator = SystemRandomNumberGenerator()
        return "\(prefix)-" + String((0..<21).map { _ in alphabet[Int(generator.next() % 64)] })
    }

    enum CodingKeys: String, CodingKey {
        case type = "event_type"
        case timestampMS = "timestamp_ms"
        case correlationID = "correlation_id"
        case taskID = "task_id"
        case agentID = "agent_id"
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        timestampMS = try container.decode(UInt64.self, forKey: .timestampMS)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data) ?? .null
    }

    /// Upstream serializes absent ids as `null`, not as missing keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestampMS, forKey: .timestampMS)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(data, forKey: .data)
    }
}

/// Well-known event types (upstream's names), for publishers and subscribers to share.
public enum BusEventType {
    public static let planningUpdated = "PlanningUpdated"
    public static let planningCommitted = "PlanningCommitted"
}

/// In-process publish/subscribe (upstream `event_bus.rs`, a tokio broadcast channel). Every
/// subscriber gets its own `AsyncStream` buffering the newest `limit` events: a slow subscriber
/// loses its oldest events, the publisher never waits for it.
public actor EventBus {
    /// Upstream's channel capacity.
    public static let defaultBufferLimit = 1024

    private var subscribers: [UUID: AsyncStream<BusEvent>.Continuation] = [:]

    public init() {}

    public func publish(_ event: BusEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Stamps and publishes an event (upstream `publish_event_simple`).
    public func publish(_ type: String, correlationID: String, taskID: String? = nil, agentID: String? = nil,
                        data: JSONValue = .object([:])) {
        publish(BusEvent(type: type, correlationID: correlationID, taskID: taskID, agentID: agentID, data: data))
    }

    /// Events published from now on. The stream ends when `finishAll` runs; cancelling its
    /// consumer unsubscribes it.
    public func subscribe(bufferLimit: Int = defaultBufferLimit) -> AsyncStream<BusEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BusEvent.self,
                                                            bufferingPolicy: .bufferingNewest(max(1, bufferLimit)))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    public var subscriberCount: Int { subscribers.count }

    /// Ends every subscriber's stream (app shutdown).
    public func finishAll() {
        let all = subscribers.values
        subscribers.removeAll()
        all.forEach { $0.finish() }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
