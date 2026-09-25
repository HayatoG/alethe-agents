import Foundation

/// A counter with the last and summed value (upstream `MetricData`).
public struct MetricData: Codable, Equatable, Hashable, Sendable {
    public var count: Int
    public var lastValue: Double
    public var sum: Double

    public init(count: Int = 0, lastValue: Double = 0, sum: Double = 0) {
        self.count = count
        self.lastValue = lastValue
        self.sum = sum
    }

    enum CodingKeys: String, CodingKey {
        case count
        case lastValue = "last_value"
        case sum
    }
}

/// Metrics and traces of the bus's events (upstream `telemetry.rs`): a count per event type
/// (`alethe_event_<type lowercased>`); count, last and sum of the numeric `duration_ms`,
/// `cost_usd` and `memory_mb` data fields (`alethe_metric_<field>`); the last 500 events, filterable
/// by correlation id; and, when a logs folder is given, every event appended redacted to a rotating
/// `telemetry.jsonl`. Actor-isolated, so file writes never happen on the main thread.
public actor Telemetry {
    public static let traceLimit = 500
    public static let fileName = "telemetry.jsonl"
    /// Fields of an event's data that feed metrics (upstream's list).
    public static let metricFields: Set<String> = ["duration_ms", "cost_usd", "memory_mb"]

    private var metricsByKey: [String: MetricData] = [:]
    private var ring: [BusEvent] = []
    private let traceLimit: Int
    private let file: RotatingLogFile?

    public init(logsDirectory: URL? = nil, traceLimit: Int = Telemetry.traceLimit) {
        self.traceLimit = max(1, traceLimit)
        file = logsDirectory.map(Self.log(in:))
    }

    /// The telemetry file, rotated like `alethe.log`.
    public static func log(in directory: URL) -> RotatingLogFile {
        RotatingLogFile(url: directory.appending(path: fileName), maxBytes: 256 * 1024, keep: 3)
    }

    public static func eventKey(_ type: String) -> String { "alethe_event_\(type.lowercased())" }
    public static func metricKey(_ field: String) -> String { "alethe_metric_\(field)" }

    /// Logs, counts and keeps one event (upstream's watcher loop body).
    public func record(_ event: BusEvent) {
        append(event)
        updateMetrics(event)
        addTrace(event)
    }

    /// Records every event of `bus` until the returned task is cancelled or the bus finishes.
    public nonisolated func follow(_ bus: EventBus) async -> Task<Void, Never> {
        let stream = await bus.subscribe()
        return Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.record(event)
            }
        }
    }

    /// Upstream `get_telemetry_metrics`.
    public func metrics() -> [String: MetricData] { metricsByKey }

    /// Upstream `get_telemetry_traces`: oldest first; only `correlationID`'s when given.
    public func traces(correlationID: String? = nil) -> [BusEvent] {
        guard let correlationID else { return ring }
        return ring.filter { $0.correlationID == correlationID }
    }

    func updateMetrics(_ event: BusEvent) {
        metricsByKey[Self.eventKey(event.type), default: MetricData()].count += 1
        guard case .object(let fields) = event.data else { return }
        // Sorted so the metrics update in a stable order (upstream iterates a JSON map).
        for field in fields.keys.sorted() where Self.metricFields.contains(field) {
            guard case .number(let value) = fields[field] else { continue }
            var metric = metricsByKey[Self.metricKey(field), default: MetricData()]
            metric.count += 1
            metric.lastValue = value
            metric.sum += value
            metricsByKey[Self.metricKey(field)] = metric
        }
    }

    func addTrace(_ event: BusEvent) {
        if ring.count >= traceLimit { ring.removeFirst(ring.count - traceLimit + 1) }
        ring.append(event)
    }

    private func append(_ event: BusEvent) {
        guard let file, let line = Self.line(for: event) else { return }
        file.append(line)
    }

    /// One JSON line with every secret-looking value redacted.
    public static func line(for event: BusEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { return nil }
        return SecretRedactor.redact(String(decoding: data, as: UTF8.self))
    }
}
