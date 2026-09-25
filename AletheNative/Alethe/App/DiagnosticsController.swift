import AletheFoundation
import AppKit
import Foundation
import MetricKit
import Observation
import UniformTypeIdentifiers

/// What the after-crash notice shows: the run that did not exit cleanly and its crash records.
struct CrashNotice: Hashable {
    var previous: SessionMarker
    var artifacts: [CrashArtifact]
}

/// Logs, diagnostics and the crash report (P5-11; upstream `logging.rs`, `crash_watch.rs`,
/// `diagnostics.rs` `export_logs`, `AuditModal`). Nothing leaves the Mac unless the user exports it.
@Observable
@MainActor
final class DiagnosticsController {
    /// Recorded warnings and errors of this run, newest first.
    private(set) var recent: [DiagnosticEvent] = []
    private(set) var logsDirectory: URL?
    /// The previous run's crash, when it did not exit cleanly.
    private(set) var crashNotice: CrashNotice?

    @ObservationIgnored private var marker: SessionMarkerStore?
    @ObservationIgnored private var metricKit: MetricKitCollector?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// Starts recording into `logs`, begins this run's session marker and, when the previous run
    /// crashed, gathers its crash records for the notice.
    func start(logs: URL) async {
        guard logsDirectory == nil else { return }
        logsDirectory = logs
        Diagnostics.shared.configure(logsDirectory: logs)
        observer = NotificationCenter.default.addObserver(forName: Diagnostics.didChange, object: Diagnostics.shared,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recent = Diagnostics.shared.recent }
        }
        recent = Diagnostics.shared.recent
        let collector = MetricKitCollector(directory: logs.appending(path: CrashEvidence.metricKitFolder))
        collector.start()
        metricKit = collector

        let store = SessionMarkerStore(logsDirectory: logs)
        marker = store
        let context = DiagnosticsContext.current()
        let current = SessionMarker(appVersion: context.appVersion, build: context.build,
                                    processID: ProcessInfo.processInfo.processIdentifier)
        let metricKitDirectory = logs.appending(path: CrashEvidence.metricKitFolder)
        let previous = await Task.detached { store.begin(current) }.value
        guard let crashed = previous.uncleanMarker else { return }
        AppLog.record(.warning, .app, "The previous session (\(crashed.appVersion), started \(crashed.startedAt.formatted(.iso8601))) did not exit cleanly")
        let artifacts = await Task.detached {
            CrashEvidence.find(since: crashed.startedAt, metricKitDirectory: metricKitDirectory)
        }.value
        crashNotice = CrashNotice(previous: crashed, artifacts: artifacts)
    }

    /// Called as the app quits normally.
    func markCleanExit() {
        marker?.markCleanExit()
    }

    func clearRecent() {
        Diagnostics.shared.clearRecent()
    }

    // MARK: - Actions (each one starts from an explicit user choice)

    func openLogsFolder() {
        guard let logsDirectory else { return }
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDirectory)
    }

    /// Diagnostics › Export: the recorded warnings and errors as JSON (SET-11).
    func exportReport() {
        let date = Date.now.formatted(.iso8601.year().month().day())
        guard let destination = savePanel(name: "Alethe-diagnostics-\(date).json", type: .json) else { return }
        let report = DiagnosticsReport(context: .current(), events: Diagnostics.shared.recent)
        do {
            try report.json().write(to: destination, options: .atomic)
        } catch {
            AppLog.record(.error, .app, "Diagnostics export failed: \(error.localizedDescription)")
        }
    }

    /// Help › Export Logs…: this run's unified log, the warnings-and-errors file, the spawn log and
    /// the session marker, redacted, in one zip.
    func exportLogs() {
        let date = Date.now.formatted(.iso8601.year().month().day())
        guard let destination = savePanel(name: "Alethe-logs-\(date).zip", type: .zip) else { return }
        let session = marker
        Task.detached {
            let input = LogExport.Input(
                context: .current(),
                currentRun: (try? LogExport.currentRunLines()) ?? [],
                journal: Diagnostics.shared.journalEvents(),
                spawnLog: Diagnostics.shared.spawnLogText(),
                session: session?.read()
            )
            do {
                try Self.zip(LogExport.files(input), to: destination)
            } catch {
                AppLog.record(.error, .app, "Log export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens a crash record in its default app (Console for `.ips`).
    func view(_ artifact: CrashArtifact) {
        NSWorkspace.shared.open(artifact.url)
    }

    /// Saves a copy of a crash record where the user chooses (text is redacted like the logs).
    func export(_ artifact: CrashArtifact) {
        let type = UTType(filenameExtension: artifact.url.pathExtension) ?? .data
        guard let destination = savePanel(name: artifact.url.lastPathComponent, type: type) else { return }
        let source = artifact.url
        Task.detached {
            do {
                let data = try Data(contentsOf: source)
                let text = String(data: data, encoding: .utf8).map { Data(SecretRedactor.redact($0).utf8) }
                try (text ?? data).write(to: destination, options: .atomic)
            } catch {
                AppLog.record(.error, .app, "Crash report export failed: \(error.localizedDescription)")
            }
        }
    }

    func dismissCrashNotice() {
        crashNotice = nil
    }

    private func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes the files into a temporary folder and zips it (the file coordinator's `.forUploading`
    /// read produces a zip of a folder).
    nonisolated private static func zip(_ files: [(name: String, data: Data)], to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "alethe-logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = staging.appending(path: "Alethe logs", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try LogExport.write(files, into: folder)
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            do {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: zip, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}

/// Saves MetricKit diagnostic payloads that carry crash diagnostics into `logs/metrickit/`, where the
/// after-crash notice finds them. MetricKit delivers them at the next launch.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = payload.timeStampEnd.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let file = directory.appending(path: "crash-\(stamp).json")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? payload.jsonRepresentation().write(to: file, options: .atomic)
            // Dated by the crash, not by this launch, so an old payload never reads as a new crash.
            try? FileManager.default.setAttributes([.modificationDate: payload.timeStampEnd], ofItemAtPath: file.path)
        }
    }
}
