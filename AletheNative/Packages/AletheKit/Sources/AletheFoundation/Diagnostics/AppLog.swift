import Foundation
import os

/// Areas of the app, one OSLog category each (`log stream --predicate 'subsystem == "com.kc1t.alethe.mac"'`).
public enum LogDomain: String, CaseIterable, Codable, Sendable {
    case app, terminal, agents, git, integrations, persistence, orchestrator
}

public enum DiagnosticLevel: String, CaseIterable, Codable, Sendable {
    case warning, error, fault

    var osLogType: OSLogType {
        switch self {
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }
}

/// A warning or error the app recorded: shown in Help › Diagnostics… and kept in the log file.
public struct DiagnosticEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var level: DiagnosticLevel
    public var domain: LogDomain
    public var message: String

    public init(id: UUID = UUID(), date: Date = .now, level: DiagnosticLevel, domain: LogDomain, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.domain = domain
        self.message = message
    }
}

/// `os.Logger` per domain. Interpolated values go out as `.private`: paths, commands and messages
/// may carry user data, and only the user's own machine should see them in clear.
public enum AppLog {
    public static let subsystem = AppIdentity.bundleIdentifier

    private static let loggers: [LogDomain: Logger] = Dictionary(
        uniqueKeysWithValues: LogDomain.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    public static func logger(_ domain: LogDomain) -> Logger {
        loggers[domain] ?? Logger(subsystem: subsystem, category: domain.rawValue)
    }

    /// Informational trace (OSLog only; never written to the log file).
    public static func info(_ domain: LogDomain, _ message: String) {
        logger(domain).info("\(message, privacy: .private)")
    }

    /// An error message the UI just showed, recorded too (upstream records what `AuditModal` lists).
    /// Nil or empty (the message was cleared) records nothing.
    public static func shown(_ message: String?, _ domain: LogDomain, level: DiagnosticLevel = .error) {
        guard let message, !message.isEmpty else { return }
        record(level, domain, message)
    }

    /// A warning, error or fault: OSLog, the recent list and the rotating log file (`Diagnostics.shared`).
    public static func record(_ level: DiagnosticLevel, _ domain: LogDomain, _ message: String) {
        Diagnostics.shared.record(level, domain, message)
    }
}
