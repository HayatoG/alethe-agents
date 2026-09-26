import Darwin
import Foundation
import Testing
@testable import AletheOrchestrator

private let start = ProcessStartTime(seconds: 1_790_000_000, microseconds: 123_456)

private func record(pid: pid_t = 4242, executables: [String] = ["/opt/homebrew/bin/codex"],
                    startTime: ProcessStartTime = start) -> WorkerRecord {
    WorkerRecord(pid: pid, groupID: pid, executables: executables, startTime: startTime, jobID: "job-01")
}

private func live(pid: pid_t = 4242, executable: String? = "/opt/homebrew/bin/codex",
                  startTime: ProcessStartTime = start) -> LiveProcess {
    LiveProcess(pid: pid, groupID: pid, startTime: startTime, executable: executable)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "workers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(1))) struct WorkerRegistryTests {
    @Test func aWorkerMatchesByPidExecutableAndStartTime() {
        #expect(WorkerRegistry.matches(record(), live: live()))
        #expect(WorkerRegistry.matches(record(executables: ["/usr/bin/env", "/usr/local/bin/node"]),
                                       live: live(executable: "/usr/local/bin/node")),
                "an npm CLI is node once it runs")
    }

    @Test func aReusedPidIsNeverTakenForAWorker() {
        #expect(!WorkerRegistry.matches(record(), live: nil), "gone")
        #expect(!WorkerRegistry.matches(record(), live: live(startTime: ProcessStartTime(seconds: start.seconds, microseconds: 0))),
                "same pid and executable, started at another instant")
        #expect(!WorkerRegistry.matches(record(), live: live(executable: "/bin/zsh")),
                "a shell whose command line might mention codex is not codex")
        #expect(!WorkerRegistry.matches(record(), live: live(executable: nil)), "unreadable image")
        #expect(!WorkerRegistry.matches(record(), live: live(pid: 4243)))
    }

    @Test func recordsFromAnotherBootAreDropped() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = WorkerRegistry(profileDirectory: folder)
        registry.add(record())
        let reader = WorkerRegistry(profileDirectory: folder)
        #expect(reader.leftovers().map(\.pid) == [4242])
        #expect(reader.leftovers(currentBoot: ProcessStartTime(seconds: 1, microseconds: 0)).isEmpty)
    }

    @Test func anUnreadableFileHasNoLeftovers() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: folder.appending(path: WorkerRegistry.fileName))
        #expect(WorkerRegistry(profileDirectory: folder).leftovers().isEmpty)
    }

    @Test func addingAnExecutableAndRemovingAreWritten() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = WorkerRegistry(profileDirectory: folder)
        registry.add(record(executables: ["/usr/bin/env"]))
        registry.noteExecutable("/usr/local/bin/node", for: 4242)
        registry.noteExecutable("/usr/local/bin/node", for: 4242)
        #expect(WorkerRegistry(profileDirectory: folder).leftovers().first?.executables == ["/usr/bin/env", "/usr/local/bin/node"])
        registry.remove(pid: 4242)
        #expect(WorkerRegistry(profileDirectory: folder).leftovers().isEmpty)
    }

    @Test func theNextLaunchEndsAMatchingLeftoverAndSparesTheRest() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["PATH": "/usr/bin:/bin"]
        // A worker from "the crashed run", recorded as it would be. `/bin/bash`, not `/bin/sh`: the
        // latter is a shim that re-execs bash, and a worker that never prints a line never gets its
        // new image noted, so whether it matched would depend on when the spawn read its image.
        let crashed = WorkerRegistry(profileDirectory: folder)
        let leftover = try WorkerProcess.spawn(
            Launcher(kind: "test", program: URL(filePath: "/bin/bash"), arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]),
            in: URL(filePath: "/tmp"), environment: environment, registry: crashed)
        // A process holding a recorded pid that is not the recorded one (wrong start time).
        let bystander = try WorkerProcess.spawn(
            Launcher(kind: "test", program: URL(filePath: "/bin/sleep"), arguments: ["60"]),
            in: URL(filePath: "/tmp"), environment: environment)
        let bystanderLive = try #require(WorkerProcessTable.process(bystander.pid))
        crashed.add(WorkerRecord(pid: bystander.pid, groupID: bystander.pid, executables: [bystanderLive.executable ?? "/bin/sleep"],
                                 startTime: ProcessStartTime(seconds: bystanderLive.startTime.seconds - 10, microseconds: 0),
                                 jobID: nil))

        let next = WorkerRegistry(profileDirectory: folder)
        let ended = await next.terminateLeftovers(grace: .milliseconds(300))
        #expect(ended == [leftover.pid])
        // Our own child in this test, so it lingers as a zombie until reaped: poll for its exit.
        let deadline = ContinuousClock.now + .seconds(2)
        while await leftover.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await !leftover.isRunning, "it was killed")
        #expect(await bystander.isRunning, "never matched by pid alone")
        #expect(next.leftovers().isEmpty, "the file starts over")

        await leftover.terminate()
        await bystander.terminate()
    }
}
