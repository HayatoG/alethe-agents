import Foundation
import Testing
@testable import AletheIntegrations

@Suite(.timeLimit(.minutes(1))) struct AiMemoryDetectionTests {
    @Test func versionIsTheTrimmedOutputOfASuccessfulRun() {
        #expect(AiMemory.parseVersion(output: "ai-memory 0.9.2\n", exitCode: 0) == "ai-memory 0.9.2")
        #expect(AiMemory.parseVersion(output: "  1.2.0  \n\n", exitCode: 0) == "1.2.0")
    }

    @Test func noVersionForAFailureOrAnEmptyAnswer() {
        #expect(AiMemory.parseVersion(output: "ai-memory 0.9.2", exitCode: 1) == nil)
        #expect(AiMemory.parseVersion(output: " \n", exitCode: 0) == nil)
        #expect(AiMemory.parseVersion(output: "", exitCode: 0) == nil)
    }

    @Test func installedOnlyOnAZeroExit() {
        #expect(AiMemory.isInstalled(exitCode: 0))
        #expect(!AiMemory.isInstalled(exitCode: 127))
        #expect(!AiMemory.isInstalled(exitCode: 15))
        #expect(!AiMemory.isInstalled(exitCode: nil))
    }

    @Test func missingExecutableIsNotInstalled() async {
        let status = await AiMemory.detect(executable: nil, endpointTimeout: .milliseconds(50))
        #expect(status.executable == nil)
        #expect(!status.installed)
        #expect(status.version == nil)
    }

    @Test func detectionReadsTheVersionOfAScript() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AiMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appending(path: "ai-memory")
        try "#!/bin/sh\necho 'ai-memory 0.9.2'\n".write(to: good, atomically: true, encoding: .utf8)
        let bad = folder.appending(path: "broken")
        try "#!/bin/sh\necho oops\nexit 2\n".write(to: bad, atomically: true, encoding: .utf8)
        for file in [good, bad] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let found = await AiMemory.detect(executable: good.path, endpointTimeout: .milliseconds(50))
        #expect(found.installed)
        #expect(found.version == "ai-memory 0.9.2")
        #expect(found.executable == good.path)

        let broken = await AiMemory.detect(executable: bad.path, endpointTimeout: .milliseconds(50))
        #expect(!broken.installed)
        #expect(broken.version == nil)
    }

    @Test func aHangingCLIIsCutOffAtTheTimeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AiMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let slow = folder.appending(path: "ai-memory")
        try "#!/bin/sh\nexec sleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)

        let started = ContinuousClock.now
        let status = await AiMemory.detect(executable: slow.path, timeout: .milliseconds(300), endpointTimeout: .milliseconds(50))
        #expect(!status.installed)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func endpointIsTheUpstreamLoopbackPort() {
        #expect(AiMemory.endpoint == "127.0.0.1:49374")
    }

    @Test func closedLoopbackPortIsNotRunning() async {
        // Port 9 (discard) has no listener on a developer Mac.
        #expect(await !LoopbackProbe.isListening(host: "127.0.0.1", port: 9, timeout: .milliseconds(200)))
    }
}

@Suite struct AiMemoryWiringTests {
    private let executable = "/opt/homebrew/bin/ai-memory"

    @Test func offWiresNothing() {
        #expect(AiMemory.server(enabled: false, executable: executable, status: nil) == nil)
        let healthy = AiMemoryStatus(executable: executable, installed: true, running: true, version: "1.0")
        #expect(AiMemory.server(enabled: false, executable: executable, status: healthy) == nil)
    }

    @Test func onWiresTheStdioServer() {
        let server = AiMemory.server(enabled: true, executable: executable, status: nil)
        #expect(server == AiMemoryServer(name: "ai-memory", command: executable, arguments: ["mcp"]))
    }

    @Test func onWithoutAnExecutableWiresNothing() {
        #expect(AiMemory.server(enabled: true, executable: nil, status: nil) == nil)
        #expect(AiMemory.server(enabled: true, executable: "", status: nil) == nil)
    }

    @Test func aBrokenExecutableIsNotWired() {
        let broken = AiMemoryStatus(executable: executable, installed: false, running: false, version: nil)
        #expect(AiMemory.server(enabled: true, executable: executable, status: broken) == nil)
    }

    @Test func detectionOfAnotherExecutableDoesNotBlockTheOverride() {
        let broken = AiMemoryStatus(executable: "/usr/local/bin/ai-memory", installed: false, running: false, version: nil)
        #expect(AiMemory.server(enabled: true, executable: executable, status: broken)?.command == executable)
    }

    @Test func runningIsNotRequired() {
        let stopped = AiMemoryStatus(executable: executable, installed: true, running: false, version: "1.0")
        #expect(AiMemory.server(enabled: true, executable: executable, status: stopped) != nil)
    }
}
