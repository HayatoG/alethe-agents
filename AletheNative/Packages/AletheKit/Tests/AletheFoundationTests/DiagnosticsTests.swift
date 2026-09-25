import Foundation
import Testing
@testable import AletheFoundation

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "alethe-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Secrets of every shape the redactor knows, embedded in ordinary log text.
private let secrets = [
    "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv",
    "ghp_0123456789abcdefghijABCDEFGHIJ",
    "xoxb-1234567890-abcdefghij",
    "AKIAIOSFODNN7EXAMPLE",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl",
    "hunter2-password-value",
    "bearer-token-value-123",
    "mcp-env-secret-value",
]

private let leakyText = """
    spawn claude --api-key \(secrets[0]) in /tmp
    git push https://user:\(secrets[5])@github.com/o/r.git failed
    GITHUB_TOKEN=\(secrets[1]) SLACK=\(secrets[2]) aws \(secrets[3])
    Authorization: Bearer \(secrets[6]) jwt \(secrets[4])
    {"env": {"OPENAI_API_KEY": "\(secrets[7])"}}
    """

private func assertNoSecrets(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for secret in secrets {
        #expect(!text.contains(secret), "leaked \(secret)", sourceLocation: sourceLocation)
    }
}

struct SecretRedactorTests {
    @Test func removesEveryKnownShape() {
        let redacted = SecretRedactor.redact(leakyText)
        assertNoSecrets(redacted)
        #expect(redacted.contains(SecretRedactor.placeholder))
    }

    @Test func keepsOrdinaryText() {
        let text = "Terminal exited with code 1 in /Users/me/project (claude, 3 panes)"
        #expect(SecretRedactor.redact(text) == text)
    }
}

struct SessionMarkerTests {
    private func marker(_ pid: Int32 = 1) -> SessionMarker {
        SessionMarker(startedAt: Date(timeIntervalSince1970: 1_000), appVersion: "2.0", build: "1", processID: pid)
    }

    @Test func firstLaunchHasNoPreviousSession() {
        let store = SessionMarkerStore(logsDirectory: temporaryDirectory())
        #expect(store.begin(marker()) == .none)
        #expect(store.read()?.cleanExit == false)
    }

    @Test func cleanQuitIsReportedClean() {
        let store = SessionMarkerStore(logsDirectory: temporaryDirectory())
        store.begin(marker(1))
        store.markCleanExit()
        let previous = store.begin(marker(2))
        guard case .clean(let last) = previous else {
            Issue.record("expected a clean previous session, got \(previous)")
            return
        }
        #expect(last.processID == 1 && last.endedAt != nil)
        #expect(previous.uncleanMarker == nil)
    }

    @Test func missingCleanExitIsReportedUnclean() {
        let store = SessionMarkerStore(logsDirectory: temporaryDirectory())
        store.begin(marker(1))
        let previous = store.begin(marker(2))
        #expect(previous.uncleanMarker?.processID == 1)
        // The new session replaces it: a third launch after a clean quit is clean again.
        store.markCleanExit()
        #expect(store.begin(marker(3)).uncleanMarker == nil)
    }

    @Test func beginNeverStoresACleanMarker() {
        let store = SessionMarkerStore(logsDirectory: temporaryDirectory())
        var seeded = marker()
        seeded.cleanExit = true
        store.begin(seeded)
        #expect(store.read()?.cleanExit == false)
    }

    @Test func unreadableMarkerCountsAsNone() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionMarkerStore(logsDirectory: directory)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.begin(marker()) == .none)
    }

    @Test func markCleanExitWithoutSessionDoesNothing() {
        let store = SessionMarkerStore(logsDirectory: temporaryDirectory())
        store.markCleanExit()
        #expect(store.read() == nil)
    }
}

struct DiagnosticsRecorderTests {
    @Test func recentIsNewestFirstAndBounded() {
        let diagnostics = Diagnostics()
        for index in 0..<(Diagnostics.recentLimit + 5) {
            diagnostics.record(.error, .git, "failure \(index)")
        }
        #expect(diagnostics.recent.count == Diagnostics.recentLimit)
        #expect(diagnostics.recent.first?.message == "failure \(Diagnostics.recentLimit + 4)")
        diagnostics.clearRecent()
        #expect(diagnostics.recent.isEmpty)
    }

    @Test func journalOutlivesTheRunRedacted() {
        let directory = temporaryDirectory()
        Diagnostics(logsDirectory: directory).record(.warning, .persistence, "saved with \(leakyText)")
        let nextRun = Diagnostics(logsDirectory: directory)
        #expect(nextRun.recent.isEmpty)
        let events = nextRun.journalEvents()
        #expect(events.count == 1)
        #expect(events.first?.domain == .persistence && events.first?.level == .warning)
        assertNoSecrets(events.map(\.message).joined())
        let raw = (try? String(contentsOf: directory.appending(path: Diagnostics.journalName), encoding: .utf8)) ?? ""
        assertNoSecrets(raw)
    }

    @Test func spawnLogRedactsCommands() {
        let directory = temporaryDirectory()
        let diagnostics = Diagnostics(logsDirectory: directory)
        diagnostics.recordSpawn("started claude --api-key \(secrets[0])")
        let text = diagnostics.spawnLogText()
        #expect(text.contains("started claude"))
        assertNoSecrets(text)
    }
}

struct RotatingLogFileTests {
    @Test func rotatesAndKeepsTheNewest() {
        let directory = temporaryDirectory()
        let file = RotatingLogFile(url: directory.appending(path: "test.log"), maxBytes: 64, keep: 3)
        for index in 0..<20 { file.append("line \(index) padding padding") }
        #expect(file.files.count == 3)
        let text = file.readAll()
        #expect(text.contains("line 19"))
        #expect(!text.contains("line 0 "))
        // Oldest first.
        let lines = text.split(separator: "\n")
        #expect(lines.last?.hasPrefix("line 19") == true)
    }
}

struct LogExportTests {
    private let context = DiagnosticsContext(appVersion: "2.0", build: "42", system: "macOS 26")

    @Test func assemblesEveryFileRedacted() {
        let session = SessionMarker(appVersion: "2.0", build: "42", processID: 7)
        let input = LogExport.Input(
            context: context,
            currentRun: ["[terminal] info: \(leakyText)"],
            journal: [DiagnosticEvent(level: .error, domain: .integrations, message: leakyText)],
            spawnLog: "started \(leakyText)",
            session: session
        )
        let files = LogExport.files(input)
        #expect(files.map(\.name) == [LogExport.aboutName, LogExport.currentRunName, LogExport.journalName,
                                      Diagnostics.spawnLogName, Diagnostics.sessionMarkerName])
        for file in files {
            assertNoSecrets(String(decoding: file.data, as: UTF8.self))
        }
        let about = String(decoding: files[0].data, as: UTF8.self)
        #expect(about.contains("2.0 (42)"))
        let journal = String(decoding: files[2].data, as: UTF8.self)
        #expect(journal.contains("[integrations] error:"))
    }

    @Test func omitsTheMarkerWhenThereIsNone() {
        let input = LogExport.Input(context: context, currentRun: [], journal: [], spawnLog: "", session: nil)
        #expect(!LogExport.files(input).map(\.name).contains(Diagnostics.sessionMarkerName))
    }

    @Test func writesTheFilesIntoAFolder() throws {
        let folder = temporaryDirectory()
        let input = LogExport.Input(context: context, currentRun: ["one"], journal: [], spawnLog: "", session: nil)
        try LogExport.write(LogExport.files(input), into: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(names) == [LogExport.aboutName, LogExport.currentRunName, LogExport.journalName, Diagnostics.spawnLogName])
    }

    @Test func diagnosticsReportIsRedactedJSON() throws {
        let report = DiagnosticsReport(context: context,
                                       events: [DiagnosticEvent(level: .fault, domain: .agents, message: leakyText)])
        let data = try report.json()
        assertNoSecrets(String(decoding: data, as: UTF8.self))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsReport.self, from: data)
        #expect(decoded.events.count == 1 && decoded.events[0].domain == .agents && decoded.context == context)
    }
}

struct CrashEvidenceTests {
    private func touch(_ url: URL, at date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func offersTheNewestReportAndRecentPayloads() throws {
        let root = temporaryDirectory()
        let reports = root.appending(path: "DiagnosticReports"), metricKit = root.appending(path: "metrickit")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try touch(reports.appending(path: "Alethe-2026-01-01-000000.ips"), at: start.addingTimeInterval(-3_600))
        try touch(reports.appending(path: "Alethe-2026-01-02-000000.ips"), at: start.addingTimeInterval(60))
        try touch(reports.appending(path: "Alethe-2026-01-03-000000.ips"), at: start.addingTimeInterval(120))
        try touch(reports.appending(path: "Other-2026-01-04-000000.ips"), at: start.addingTimeInterval(180))
        try touch(reports.appending(path: "Alethe-2026-01-05-000000.diag"), at: start.addingTimeInterval(240))
        try touch(metricKit.appending(path: "old.json"), at: start.addingTimeInterval(-60))
        try touch(metricKit.appending(path: "new.json"), at: start.addingTimeInterval(30))

        let found = CrashEvidence.find(since: start, reportDirectories: [reports], metricKitDirectory: metricKit)
        #expect(found.map(\.url.lastPathComponent) == ["Alethe-2026-01-03-000000.ips", "new.json"])
        #expect(found.map(\.kind) == [.systemReport, .metricKit])
    }

    @Test func findsNothingWithoutFolders() {
        let root = temporaryDirectory()
        #expect(CrashEvidence.find(since: nil, reportDirectories: [root], metricKitDirectory: nil).isEmpty)
    }
}
