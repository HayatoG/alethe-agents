import Darwin
import Foundation
import Synchronization
import AletheFoundation

/// One live worker as written to `orchestrator-workers.json`.
public struct WorkerRecord: Hashable, Sendable, Codable {
    /// The worker's pid, which is also its process group (it leads its own group).
    public var pid: pid_t
    public var groupID: pid_t
    /// Every image the process was seen running: the program at spawn and what it became after
    /// exec (an npm CLI's `#!/usr/bin/env node` ends as node), read once it answered.
    public var executables: [String]
    public var startTime: ProcessStartTime
    public var jobID: String?

    public init(pid: pid_t, groupID: pid_t, executables: [String], startTime: ProcessStartTime, jobID: String?) {
        self.pid = pid
        self.groupID = groupID
        self.executables = executables
        self.startTime = startTime
        self.jobID = jobID
    }
}

/// Live workers on disk (`<profile>/orchestrator-workers.json`), so the launch after a crash can end
/// the groups the dead app left behind. A worker matches only when the process with its pid still
/// runs one of its recorded executables and started at the recorded instant — never by command line,
/// which any shell or editor mentioning the same words would share (as the browser sweep, P5-19).
/// Workers usually exit on their own once their stdin closes with the app; this is the backstop.
public final class WorkerRegistry: Sendable {
    public static let fileName = "orchestrator-workers.json"

    private struct Document: Codable {
        var version = 1
        var bootTime: ProcessStartTime?
        var workers: [WorkerRecord] = []
    }

    public let url: URL
    private let state = Mutex<[WorkerRecord]>([])

    public init(url: URL) {
        self.url = url
    }

    public convenience init(profileDirectory: URL) {
        self.init(url: profileDirectory.appending(path: Self.fileName))
    }

    public var records: [WorkerRecord] { state.withLock { $0 } }

    public static var currentBootTime: ProcessStartTime? { WorkerProcessTable.bootTime() }

    public func add(_ record: WorkerRecord) {
        state.withLock { records in
            records.removeAll { $0.pid == record.pid }
            records.append(record)
            write(records)
        }
    }

    /// Adds an image the worker was seen running (after its exec settled).
    public func noteExecutable(_ executable: String, for pid: pid_t) {
        state.withLock { records in
            guard let index = records.firstIndex(where: { $0.pid == pid }),
                  !records[index].executables.contains(executable) else { return }
            records[index].executables.append(executable)
            write(records)
        }
    }

    public func remove(pid: pid_t) {
        state.withLock { records in
            let before = records.count
            records.removeAll { $0.pid == pid }
            if records.count != before { write(records) }
        }
    }

    /// Whether `live`, the process now holding a record's pid, is that worker.
    public static func matches(_ record: WorkerRecord, live: LiveProcess?) -> Bool {
        guard let live, live.pid == record.pid, live.startTime == record.startTime,
              let executable = live.executable else { return false }
        return record.executables.contains(executable)
    }

    /// Records written by an earlier run, dropped when they come from another boot (their pids name
    /// nothing now) or cannot be read.
    public func leftovers(currentBoot: ProcessStartTime? = WorkerRegistry.currentBootTime) -> [WorkerRecord] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        guard document.bootTime == nil || currentBoot == nil || document.bootTime == currentBoot else { return [] }
        return document.workers
    }

    /// Ends every leftover worker that still matches (SIGTERM to its group, SIGKILL to the tree after
    /// `grace`), then starts the file over with this run's workers. Call once at launch, before the
    /// first spawn. Returns the pids that were ended.
    @concurrent
    public func terminateLeftovers(
        grace: Duration = WorkerProcess.terminationGrace,
        lookup: (@Sendable (pid_t) -> LiveProcess?)? = nil
    ) async -> [pid_t] {
        let lookup = lookup ?? { WorkerProcessTable.process($0) }
        let own = getpid()
        let current = Set(records.map(\.pid))
        let stale = leftovers().filter { record in
            !current.contains(record.pid) && record.pid != own && record.pid > 1
                && Self.matches(record, live: lookup(record.pid))
        }
        for record in stale {
            Darwin.kill(-record.groupID, SIGTERM)
            Darwin.kill(record.pid, SIGTERM)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while stale.contains(where: { Self.matches($0, live: lookup($0.pid)) }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for record in stale {
            // Not our child, so it cannot be reaped here: launchd reaps it once it dies.
            WorkerProcessTable.killTree(leader: record.pid, leaderAlive: Self.matches(record, live: lookup(record.pid)))
        }
        if !stale.isEmpty {
            AppLog.record(.warning, .orchestrator, "Ended \(stale.count) worker(s) left by an earlier run")
        }
        state.withLock { write($0) }
        return stale.map(\.pid)
    }

    /// Atomic (tmp → rename); a failure is logged and the next change tries again.
    private func write(_ records: [WorkerRecord]) {
        let document = Document(bootTime: WorkerProcessTable.bootTime(), workers: records)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(document).write(to: url, options: .atomic)
        } catch {
            AppLog.record(.warning, .orchestrator, "Could not record live workers: \(error)")
        }
    }
}
