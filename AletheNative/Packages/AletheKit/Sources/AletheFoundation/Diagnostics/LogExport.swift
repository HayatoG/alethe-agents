import Foundation
import OSLog

/// Facts about the build and the machine that head every export.
public struct DiagnosticsContext: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var system: String

    public init(appVersion: String, build: String, system: String) {
        self.appVersion = appVersion
        self.build = build
        self.system = system
    }

    public static func current(bundle: Bundle = .main) -> DiagnosticsContext {
        DiagnosticsContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

/// Help › Diagnostics… › Export (upstream `AuditModal` "export JSON", SET-11).
public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public var exportedAt: Date
    public var context: DiagnosticsContext
    public var events: [DiagnosticEvent]

    public init(exportedAt: Date = .now, context: DiagnosticsContext, events: [DiagnosticEvent]) {
        self.exportedAt = exportedAt
        self.context = context
        self.events = events
    }

    /// Pretty JSON with every message redacted again (events recorded before a rule existed).
    public func json() throws -> Data {
        var copy = self
        copy.events = events.map { event in
            var event = event
            event.message = SecretRedactor.redact(event.message)
            return event
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }
}

/// Help › Export Logs… (upstream `export_logs`): the files that go into the archive, each redacted.
public enum LogExport {
    public struct Input: Sendable {
        public var context: DiagnosticsContext
        /// This run's OSLog lines (`currentRunLines`).
        public var currentRun: [String]
        /// The rotating warnings-and-errors file: this and earlier runs.
        public var journal: [DiagnosticEvent]
        public var spawnLog: String
        public var session: SessionMarker?

        public init(context: DiagnosticsContext, currentRun: [String], journal: [DiagnosticEvent],
                    spawnLog: String, session: SessionMarker?) {
            self.context = context
            self.currentRun = currentRun
            self.journal = journal
            self.spawnLog = spawnLog
            self.session = session
        }
    }

    public static let aboutName = "about.txt"
    public static let currentRunName = "current-run.log"
    public static let journalName = "warnings-and-errors.log"

    /// File name → contents, in a stable order.
    public static func files(_ input: Input) -> [(name: String, data: Data)] {
        let about = """
            \(AppIdentity.productName) \(input.context.appVersion) (\(input.context.build))
            \(input.context.system)
            Exported \(Date.now.formatted(.iso8601))
            Session started \(input.session.map { $0.startedAt.formatted(.iso8601) } ?? "—")

            """
        let journal = input.journal.map { event in
            "\(event.date.formatted(.iso8601)) [\(event.domain.rawValue)] \(event.level.rawValue): \(event.message)"
        }
        var files: [(String, String)] = [
            (aboutName, about),
            (currentRunName, input.currentRun.joined(separator: "\n")),
            (journalName, journal.joined(separator: "\n")),
            (Diagnostics.spawnLogName, input.spawnLog),
        ]
        if let session = input.session, let data = try? SessionMarkerStore.encoder.encode(session) {
            files.append((Diagnostics.sessionMarkerName, String(decoding: data, as: UTF8.self)))
        }
        return files.map { name, text in (name, Data(SecretRedactor.redact(text).utf8)) }
    }

    /// This process's entries in the unified log (`OSLogStore`), subsystem only. Values logged as
    /// `.private` may read `<private>`; the warnings-and-errors file has them, redacted.
    public static func currentRunLines(subsystem: String = AppLog.subsystem) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return "\(log.date.formatted(.iso8601)) [\(log.category)] \(label(log.level)): \(log.composedMessage)"
        }
    }

    /// Writes `files` into `folder` (created), for zipping.
    public static func write(_ files: [(name: String, data: Data)], into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: folder.appending(path: file.name), options: .atomic)
        }
    }

    private static func label(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }
}
