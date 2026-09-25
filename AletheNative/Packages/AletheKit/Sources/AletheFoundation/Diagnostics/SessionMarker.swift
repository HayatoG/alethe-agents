import Foundation

/// The running session, written at launch with `cleanExit: false` and flipped on a normal quit
/// (upstream `crash_watch.rs`, `last_session.json`). Finding `false` at the next launch means the
/// previous run crashed, was killed or lost power.
public struct SessionMarker: Codable, Equatable, Hashable, Sendable {
    public var startedAt: Date
    public var appVersion: String
    public var build: String
    public var processID: Int32
    public var cleanExit: Bool
    public var endedAt: Date?

    public init(startedAt: Date = .now, appVersion: String, build: String, processID: Int32,
                cleanExit: Bool = false, endedAt: Date? = nil) {
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.build = build
        self.processID = processID
        self.cleanExit = cleanExit
        self.endedAt = endedAt
    }
}

/// What the previous run left behind.
public enum PreviousSession: Equatable, Sendable {
    /// No marker (first launch) or one that cannot be read.
    case none
    case clean(SessionMarker)
    case unclean(SessionMarker)

    public var uncleanMarker: SessionMarker? {
        if case .unclean(let marker) = self { marker } else { nil }
    }
}

public struct SessionMarkerStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(logsDirectory: URL) {
        self.init(url: logsDirectory.appending(path: Diagnostics.sessionMarkerName))
    }

    public func read() -> SessionMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SessionMarker.self, from: data)
    }

    /// Reports the previous run and records `current` (not yet clean) in its place.
    @discardableResult
    public func begin(_ current: SessionMarker) -> PreviousSession {
        let previous: PreviousSession = switch read() {
        case .some(let marker) where marker.cleanExit: .clean(marker)
        case .some(let marker): .unclean(marker)
        case .none: .none
        }
        var fresh = current
        fresh.cleanExit = false
        fresh.endedAt = nil
        write(fresh)
        return previous
    }

    /// Marks the current run as ended normally; nothing when no run was begun.
    public func markCleanExit(at date: Date = .now) {
        guard var marker = read() else { return }
        marker.cleanExit = true
        marker.endedAt = date
        write(marker)
    }

    private func write(_ marker: SessionMarker) {
        guard let data = try? Self.encoder.encode(marker) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
