import Foundation
import Testing
import AletheIntegrations
@testable import AletheOrchestrator

private func workspace(_ tag: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "alethe-orch-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A job as the core creates it on `alethe_delegate`.
private func delegated(_ number: UInt64, run: UInt64, spec: String, cwd: URL, label: String? = nil, status: JobStatus) -> Job {
    Job(
        id: OrchestratorID.job(number),
        plannerID: nil,
        agent: WorkerAgent.codex,
        runID: OrchestratorID.run(run),
        runLabel: label,
        spec: spec,
        cwd: cwd.path,
        status: status
    )
}

@Suite(.timeLimit(.minutes(1))) struct OrchestratorJobStoreTests {
    // Upstream `history_outlives_the_process_and_in_flight_work_is_not_reported_as_running`: the first
    // process writes the record as work is created; a new one restores it as interrupted.
    @Test func historyOutlivesTheProcessAndInFlightWorkIsNotReportedAsRunning() async throws {
        let directory = try workspace("persist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: OrchestratorJobStore.fileName)

        let first = OrchestratorJobStore(url: url)
        first.persist(jobs: [delegated(1, run: 1, spec: "keep this", cwd: directory, label: "a run", status: .running)], planners: [])
        await first.flush()
        #expect(FileManager.default.fileExists(atPath: url.path), "the store must be written as work is created")

        let second = OrchestratorJobStore(url: url).restore()
        #expect(second.outcome == .loaded)
        #expect(second.jobs.count == 1, "the record survives a new process")
        #expect(second.jobs.first?.spec == "keep this")
        #expect(second.jobs.first?.runLabel == "a run")
        #expect(second.jobs.first?.status == .interrupted, "a worker whose process is gone must not be shown as running")
        #expect(second.jobs.filter { $0.status == .running }.isEmpty, "restored work holds no slot")
    }

    // Upstream `a_new_id_never_collides_with_a_restored_one`.
    @Test func aNewIDNeverCollidesWithARestoredOne() async throws {
        let directory = try workspace("persist-ids")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: OrchestratorJobStore.fileName)

        let first = OrchestratorJobStore(url: url)
        first.persist(jobs: [
            delegated(1, run: 1, spec: "one", cwd: directory, status: .running),
            delegated(2, run: 1, spec: "two", cwd: directory, status: .queued),
        ], planners: [])
        await first.flush()

        let restored = OrchestratorJobStore(url: url).restore()
        #expect(restored.nextJobID == "job-03", "counting resumes past the restored ids")
        #expect(restored.nextRunID == "run-02")
        #expect(restored.jobs.map(\.status) == [.interrupted, .interrupted])
    }

    @Test func aFileFromTheTauriAppLoads() throws {
        let directory = try workspace("tauri")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: OrchestratorJobStore.fileName)
        let tauri = """
        {
          "version": 2,
          "jobs": [
            {"id":"job-07","plannerId":"tab-1","agent":"claude","runId":"run-04","runLabel":null,
             "spec":"s","cwd":"/r","status":"done","threadId":"t","outcome":"completed","plan":[],
             "tokens":{"totalTokens":3},"costUsd":0.5,"worktree":null,"approvalPolicy":"\\"never\\"",
             "sandbox":"workspace-write","webSearch":false,"summary":"ok","startedAt":1,"endedAt":2},
            {"plannerId":"tab-1","spec":"no id, skipped"},
            {"id":"job-09","runId":"run-05","status":"blocked"}
          ],
          "planners": [
            {"id":"tab-1","label":"Claude 1","agent":"claude"},
            {"id":"tab-2"},
            {"id":"tab-1","label":"renamed","agent":"claude"}
          ]
        }
        """
        try Data(tauri.utf8).write(to: url)

        let restored = OrchestratorJobStore(url: url).restore()
        #expect(restored.outcome == .loaded)
        #expect(restored.jobs.map(\.id) == ["job-07", "job-09"])
        #expect(restored.jobs.map(\.status) == [.done, .blocked])
        #expect(restored.jobs.first?.report == "ok")
        #expect(restored.jobCounter == 9)
        #expect(restored.runCounter == 5)
        #expect(restored.planners == [
            Planner(id: "tab-1", label: "renamed", agent: "claude"),
            Planner(id: "tab-2", label: "tab-2", agent: ""),
        ])
    }

    @Test func theWrittenFileIsUpstreamsV2Shape() async throws {
        let directory = try workspace("shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrchestratorJobStore(profileDirectory: directory)
        let planner = Planner(id: "tab-1", label: "Codex 1", agent: "codex")
        store.persist(jobs: [delegated(1, run: 1, spec: "s", cwd: directory, status: .done)], planners: [planner])
        await store.flush()

        let json = try OrderedJSON.parse(Data(contentsOf: store.url))
        let object = try #require(json.objectValue)
        #expect(object.map(\.key) == ["version", "jobs", "planners"])
        #expect(object["version"] == .integer(2))
        #expect(object["jobs"]?.arrayValue?.first == delegated(1, run: 1, spec: "s", cwd: directory, status: .done).record)
        #expect(object["planners"] == .array([planner.json]))
    }

    @Test func aCorruptFileIsSetAsideAndTheStoreStartsEmpty() async throws {
        let directory = try workspace("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrchestratorJobStore(profileDirectory: directory)
        try Data("{\"version\": 2, \"jobs\": [".utf8).write(to: store.url)

        let restored = store.restore()
        #expect(restored.outcome == .setAside(movedTo: store.backupURL))
        #expect(restored.jobs.isEmpty && restored.planners.isEmpty)
        #expect(restored.nextJobID == "job-01")
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        #expect(try String(contentsOf: store.backupURL, encoding: .utf8) == "{\"version\": 2, \"jobs\": [")

        // A root that is not an object is unreadable too.
        try Data("[]".utf8).write(to: store.url)
        #expect(store.restore().outcome == .setAside(movedTo: store.backupURL))
        #expect(try String(contentsOf: store.backupURL, encoding: .utf8) == "[]")
    }

    @Test func noFileIsAFreshStart() throws {
        let directory = try workspace("fresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = OrchestratorJobStore(profileDirectory: directory).restore()
        #expect(restored.outcome == .fresh)
        #expect(restored.jobs.isEmpty)
    }

    @Test func requestsWhileAWriteIsPendingCoalesceIntoOneWriteOfTheLatestState() async throws {
        let directory = try workspace("coalesce")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "test.job-store")
        let store = OrchestratorJobStore(url: directory.appending(path: OrchestratorJobStore.fileName), queue: queue)

        queue.suspend()
        for number in 1...50 as ClosedRange<UInt64> {
            let jobs = (1...number).map { delegated($0, run: 1, spec: "task \($0)", cwd: directory, status: .done) }
            store.persist(jobs: jobs, planners: [])
        }
        queue.resume()
        await store.flush()

        #expect(store.writeCount == 1)
        let restored = store.restore()
        #expect(restored.jobs.count == 50)
        #expect(restored.nextJobID == "job-51")

        // Nothing pending: a flush writes nothing more.
        await store.flush()
        #expect(store.writeCount == 1)
    }
}
