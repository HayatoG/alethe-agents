import Foundation
import Synchronization
import AletheIntegrations

/// `orchestrator-jobs.json` in upstream's v2 shape (`version`, job records in creation order,
/// planners), so a file written by the Tauri app loads here and the other way round.
public struct OrchestratorJobsFile: Hashable, Sendable {
    public static let version = 2

    public var jobs: [Job]
    public var planners: [Planner]

    public init(jobs: [Job] = [], planners: [Planner] = []) {
        self.jobs = jobs
        self.planners = planners
    }

    /// Upstream `persist`'s payload, key for key.
    public var json: OrderedJSON {
        [
            "version": .integer(Self.version),
            "jobs": .array(jobs.map(\.record)),
            "planners": .array(planners.map(\.json)),
        ]
    }

    /// Upstream `restore`: the version is not checked, records without an id are skipped and the
    /// in-flight ones come back interrupted (`Job.init?(record:)`). Nil when the root is no object.
    public init?(json: OrderedJSON) {
        guard let object = json.objectValue else { return nil }
        var jobs: [Job] = []
        var seenJobs = Set<String>()
        for record in object["jobs"]?.arrayValue ?? [] {
            guard let job = Job(record: record), seenJobs.insert(job.id).inserted else { continue }
            jobs.append(job)
        }
        // Upstream keeps planners in a map: a repeated id replaces the earlier entry.
        var planners: [Planner] = []
        var plannerIndex: [String: Int] = [:]
        for record in object["planners"]?.arrayValue ?? [] {
            guard let planner = Planner(json: record) else { continue }
            if let index = plannerIndex[planner.id] {
                planners[index] = planner
            } else {
                plannerIndex[planner.id] = planners.count
                planners.append(planner)
            }
        }
        self.init(jobs: jobs, planners: planners)
    }
}

/// What a launch starts from: the previous session's history and the counters past its ids.
public struct OrchestratorRestore: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// No file yet.
        case fresh
        case loaded
        /// The file could not be read; it was moved to `movedTo` (nil if even that failed).
        case setAside(movedTo: URL?)
    }

    public var jobs: [Job]
    public var planners: [Planner]
    /// The highest `job-NN` restored; the next job is `job-(jobCounter + 1)`.
    public var jobCounter: UInt64
    public var runCounter: UInt64
    public var outcome: Outcome

    public init(file: OrchestratorJobsFile, outcome: Outcome) {
        jobs = file.jobs
        planners = file.planners
        jobCounter = file.jobs.map { OrchestratorID.trailingNumber($0.id) }.max() ?? 0
        runCounter = file.jobs.map { OrchestratorID.trailingNumber($0.runID) }.max() ?? 0
        self.outcome = outcome
    }

    public var nextJobID: String { OrchestratorID.job(jobCounter + 1) }
    public var nextRunID: String { OrchestratorID.run(runCounter + 1) }
}

/// The job history that outlives the app (upstream `set_store` / `restore` / `persist`).
///
/// `persist` is called on transitions only (never on streamed tokens) and never blocks: the state is
/// handed over and written on a serial queue. Requests that arrive while a write is waiting or in
/// progress coalesce into one write of the latest state. Writes are atomic (temporary file renamed
/// over the target), so a crash leaves either the previous file or the new one.
public final class OrchestratorJobStore: Sendable {
    public static let fileName = "orchestrator-jobs.json"

    public let url: URL
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct State {
        var pending: OrchestratorJobsFile?
        var drainScheduled = false
        var writes = 0
    }

    /// `queue` is where writes happen; tests pass one they can suspend.
    public init(url: URL, queue: DispatchQueue = DispatchQueue(label: "alethe.orchestrator.job-store", qos: .utility)) {
        self.url = url
        self.queue = queue
    }

    public convenience init(profileDirectory: URL) {
        self.init(url: profileDirectory.appending(path: Self.fileName))
    }

    /// Where an unreadable file is set aside.
    public var backupURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".bak")
    }

    /// How many times the file has been written (coalescing is observable in tests).
    public var writeCount: Int { state.withLock { $0.writes } }

    /// Reads the previous session's history. Never fails: an unreadable file is moved to `.bak` and
    /// the store starts empty, so the next write does not destroy what could still be recovered.
    public func restore() -> OrchestratorRestore {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return OrchestratorRestore(file: OrchestratorJobsFile(), outcome: .fresh)
        }
        if let data = try? Data(contentsOf: url),
           let json = try? OrderedJSON.parse(data),
           let file = OrchestratorJobsFile(json: json) {
            return OrchestratorRestore(file: file, outcome: .loaded)
        }
        return OrchestratorRestore(file: OrchestratorJobsFile(), outcome: .setAside(movedTo: setAside()))
    }

    /// Asks for the state to be written; returns at once.
    public func persist(_ file: OrchestratorJobsFile) {
        let schedule = state.withLock { state -> Bool in
            state.pending = file
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    public func persist(jobs: [Job], planners: [Planner]) {
        persist(OrchestratorJobsFile(jobs: jobs, planners: planners))
    }

    /// Returns once every requested state is on disk (call on quit and before reading the file back).
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.drain()
                continuation.resume()
            }
        }
    }

    private func drain() {
        while true {
            let next = state.withLock { state -> OrchestratorJobsFile? in
                guard let pending = state.pending else {
                    state.drainScheduled = false
                    return nil
                }
                state.pending = nil
                return pending
            }
            guard let next else { return }
            write(next)
        }
    }

    private func write(_ file: OrchestratorJobsFile) {
        let data = Data(file.json.rendered().utf8)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            state.withLock { $0.writes += 1 }
        } catch {
            // Like upstream, a failed write is dropped: the next transition writes the whole state again.
        }
    }

    private func setAside() -> URL? {
        let fileManager = FileManager.default
        let backup = backupURL
        try? fileManager.removeItem(at: backup)
        do {
            try fileManager.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}
