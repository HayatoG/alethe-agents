import Foundation
import Synchronization

/// Recorder of warnings and errors (upstream `record_app_event`, `lib/auditLogger.ts`): each one goes
/// to OSLog (`.private`), to an in-memory list of the recent ones and, redacted, to a small rotating
/// JSON-lines file that outlives the run. Also keeps the spawn log. Callable from any thread.
public final class Diagnostics: Sendable {
    public static let shared = Diagnostics()
    /// Posted (on the recording thread) after an event is recorded or the list cleared.
    public static let didChange = Notification.Name("AletheDiagnosticsDidChange")
    public static let recentLimit = 300

    public static let journalName = "alethe.log"
    public static let spawnLogName = "spawn.log"
    public static let sessionMarkerName = "last_session.json"

    private struct State {
        var directory: URL?
        var recent: [DiagnosticEvent] = []
    }

    private let state = Mutex(State())

    /// Unconfigured: events are kept in memory and in OSLog only until `configure` names the folder.
    public init(logsDirectory: URL? = nil) {
        state.withLock { $0.directory = logsDirectory }
    }

    public func configure(logsDirectory: URL) {
        state.withLock { $0.directory = logsDirectory }
    }

    public var logsDirectory: URL? { state.withLock { $0.directory } }

    /// Warnings and errors, newest first (this run).
    public var recent: [DiagnosticEvent] { state.withLock { $0.recent } }

    public func clearRecent() {
        state.withLock { $0.recent.removeAll() }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func record(_ level: DiagnosticLevel, _ domain: LogDomain, _ message: String, date: Date = .now) {
        AppLog.logger(domain).log(level: level.osLogType, "\(message, privacy: .private)")
        let event = DiagnosticEvent(date: date, level: level, domain: domain,
                                    message: SecretRedactor.redact(String(message.prefix(4000))))
        state.withLock { state in
            state.recent.insert(event, at: 0)
            if state.recent.count > Self.recentLimit { state.recent.removeLast(state.recent.count - Self.recentLimit) }
            guard let directory = state.directory, let line = try? Self.lineEncoder.encode(event) else { return }
            Self.journal(in: directory).append(String(decoding: line, as: UTF8.self))
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Every recorded event in the log file (this and earlier runs), oldest first.
    public func journalEvents() -> [DiagnosticEvent] {
        guard let directory = logsDirectory else { return [] }
        let text = state.withLock { _ in Self.journal(in: directory).readAll() }
        return text.split(separator: "\n").compactMap { try? Self.lineDecoder.decode(DiagnosticEvent.self, from: Data($0.utf8)) }
    }

    /// One line in the spawn log (upstream `spawn.log`): what was started, never environment values.
    /// `domain` picks the OSLog category the line is also traced under.
    public func recordSpawn(_ line: String, domain: LogDomain = .terminal, date: Date = .now) {
        let stamped = "\(date.formatted(.iso8601)) \(SecretRedactor.redact(line.replacingOccurrences(of: "\n", with: " ")))"
        AppLog.logger(domain).info("\(stamped, privacy: .private)")
        state.withLock { state in
            guard let directory = state.directory else { return }
            Self.spawnLog(in: directory).append(stamped)
        }
    }

    public func spawnLogText() -> String {
        guard let directory = logsDirectory else { return "" }
        return state.withLock { _ in Self.spawnLog(in: directory).readAll() }
    }

    public static func journal(in directory: URL) -> RotatingLogFile {
        RotatingLogFile(url: directory.appending(path: journalName), maxBytes: 256 * 1024, keep: 3)
    }

    public static func spawnLog(in directory: URL) -> RotatingLogFile {
        RotatingLogFile(url: directory.appending(path: spawnLogName), maxBytes: 128 * 1024, keep: 2)
    }

    static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var lineDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
