import Darwin
import Foundation
import Testing
@testable import AletheTerminal

@Suite struct PTYProcessTests {
    private func run(_ launch: PTYLaunch, input: Data? = nil) async throws -> (output: String, code: Int32) {
        let process = try PTYProcess(launch)
        let collected = Collected()
        return try await withCheckedThrowingContinuation { continuation in
            process.onOutput = { collected.append($0) }
            process.onExit = { code in continuation.resume(returning: (collected.string, code)) }
            process.start()
            if let input { process.write(input) }
        }
    }

    @Test func runsCommandOnATerminalAndReportsExitCode() async throws {
        let launch = PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "test -t 0 && test -t 1 && echo tty-ok; exit 3"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp",
            size: PTYSize(columns: 100, rows: 30)
        )
        let result = try await run(launch)
        #expect(result.output.contains("tty-ok"))
        #expect(result.code == 3)
    }

    @Test func appliesInitialWindowSizeAndWorkingDirectory() async throws {
        let launch = PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "stty size; pwd"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/private/tmp",
            size: PTYSize(columns: 123, rows: 45)
        )
        let result = try await run(launch)
        #expect(result.output.contains("45 123"))
        #expect(result.output.contains("/private/tmp"))
    }

    @Test func terminateKillsAChildThatIgnoresHangup() async throws {
        let process = try PTYProcess(PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "trap '' HUP; echo ready; while :; do sleep 1; done"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: nil,
            size: PTYSize(columns: 80, rows: 24)
        ))
        let collected = Collected()
        let code: Int32 = await withCheckedContinuation { continuation in
            process.onOutput = { data in
                collected.append(data)
                if collected.string.contains("ready") { process.terminate(grace: .milliseconds(200)) }
            }
            process.onExit = { continuation.resume(returning: $0) }
            process.start()
        }
        #expect(code == 128 + SIGKILL)
    }

    @Test func coalescedResizeAppliesOnlyTheLastSize() async throws {
        let process = try PTYProcess(PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "trap 'stty size' WINCH; echo ready; read line"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: nil,
            size: PTYSize(columns: 80, rows: 24)
        ))
        let collected = Collected()
        let output: String = await withCheckedContinuation { continuation in
            process.onOutput = { data in
                collected.append(data)
                if collected.string.contains("ready"), !collected.string.contains("sent") {
                    collected.append(Data("sent".utf8))
                    for columns in UInt16(81)...UInt16(90) {
                        process.resizeCoalesced(PTYSize(columns: columns, rows: 24), quiet: .milliseconds(50))
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { process.write(Data("\n".utf8)) }
                }
            }
            process.onExit = { _ in continuation.resume(returning: collected.string) }
            process.start()
        }
        #expect(output.contains("24 90"))
        #expect(!output.contains("24 81"))
    }

    @Test func forwardsInputToTheChild() async throws {
        let launch = PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "read line; echo got:$line"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: nil,
            size: PTYSize(columns: 80, rows: 24)
        )
        let result = try await run(launch, input: Data("hello\n".utf8))
        #expect(result.output.contains("got:hello"))
    }

    @Test func childIsASessionLeaderWithTheTerminalAsControllingTTY() async throws {
        // `ps -o tpgid` is the controlling terminal's foreground group; -1 means no controlling TTY.
        let launch = PTYLaunch(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "ps -o sess=,tpgid= -p $$"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: nil,
            size: PTYSize(columns: 80, rows: 24)
        )
        let result = try await run(launch)
        #expect(!result.output.contains("-1"))
    }

    @Test func spawnFailureIsReportedThroughExitCode127() async throws {
        let launch = PTYLaunch(
            executable: "/nonexistent/binary",
            arguments: ["x"],
            environment: [:],
            workingDirectory: nil,
            size: PTYSize(columns: 80, rows: 24)
        )
        let result = try await run(launch)
        #expect(result.code == 127)
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
