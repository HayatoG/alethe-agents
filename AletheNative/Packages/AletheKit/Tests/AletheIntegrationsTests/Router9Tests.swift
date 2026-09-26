import AletheAgents
import Darwin
import Foundation
import Testing
@testable import AletheIntegrations

/// G: upstream `src/lib/router9.test.ts`.
struct Router9RoutingTests {
    private let active = Router9RoutingConfig(enabled: true, apiKey: "9r_test")

    @Test func acceptsTheAgentsWhoseCLIReadsABaseURLFromTheEnvironment() {
        #expect(Router9.supports(.claude))
        #expect(Router9.supports(.codex))
        #expect(Router9.supports(.opencode))
    }

    @Test func rejectsShellsAndAgentsWithoutADocumentedOverride() {
        #expect(!Router9.supports(.shell))
        #expect(!Router9.supports(.copilot))
        #expect(!Router9.supports(.kiro))
    }

    @Test func usesTheAnthropicDialectForClaude() {
        #expect(Router9.environment(for: .claude, config: active) == [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:20128",
            "ANTHROPIC_AUTH_TOKEN": "9r_test",
        ])
    }

    @Test func usesTheOpenAIDialectWithV1ForCodexAndOpenCode() {
        let expected = ["OPENAI_BASE_URL": "http://127.0.0.1:20128/v1", "OPENAI_API_KEY": "9r_test"]
        #expect(Router9.environment(for: .codex, config: active) == expected)
        #expect(Router9.environment(for: .opencode, config: active) == expected)
    }

    @Test func honoursACustomPort() {
        var custom = active
        custom.port = 31000
        #expect(Router9.environment(for: .claude, config: custom)["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:31000")
    }

    @Test func routesNothingWhenDisabledUnconfiguredOrUnsupported() {
        var disabled = active
        disabled.enabled = false
        #expect(Router9.environment(for: .claude, config: disabled).isEmpty)
        var blank = active
        blank.apiKey = "   "
        #expect(Router9.environment(for: .claude, config: blank).isEmpty)
        #expect(Router9.environment(for: .claude, config: nil).isEmpty)
        #expect(Router9.environment(for: .shell, config: active).isEmpty)
    }

    @Test func normalizePortFallsBackForValuesAListenerCannotBind() {
        #expect(Router9.normalizePort(0) == 20128)
        #expect(Router9.normalizePort(70000) == 20128)
        #expect(Router9.normalizePort(1.5) == 20128)
        #expect(Router9.normalizePort(3000) == 3000)
    }

    @Test func baseURLStaysOnLoopback() {
        #expect(Router9.baseURL(port: 0) == "http://127.0.0.1:20128")
        #expect(Router9.dashboardURL(port: 31000) == "http://127.0.0.1:31000/dashboard")
    }

    private func status(managed: Bool, external: Bool) -> Router9Status {
        Router9Status(
            managed: managed ? Router9Install(installed: true, version: "0.5.59") : .none,
            external: external ? Router9Install(installed: true, version: "0.5.40", path: "/usr/local/bin/9router") : .none,
            running: false, portInUse: false, port: 20128, installDirectory: "", dataDirectory: "", logPath: "",
            dashboardURL: "")
    }

    @Test func resolveSourcePrefersTheChosenSourceWhenInstalled() {
        #expect(Router9.resolveSource(status(managed: true, external: true), preferred: .external)?.source == .external)
        #expect(Router9.resolveSource(status(managed: true, external: true), preferred: .managed)?.source == .managed)
    }

    @Test func resolveSourceFallsBackToTheOtherInstall() {
        #expect(Router9.resolveSource(status(managed: true, external: false), preferred: .external)?.source == .managed)
        let external = Router9.resolveSource(status(managed: false, external: true), preferred: .managed)
        #expect(external?.source == .external)
        #expect(external?.install.path == "/usr/local/bin/9router")
    }

    @Test func resolveSourceIsNilWhenNothingIsInstalled() {
        #expect(Router9.resolveSource(status(managed: false, external: false), preferred: .managed) == nil)
        #expect(Router9.resolveSource(nil, preferred: .managed) == nil)
    }

    @Test func hasInstallWhenEitherInstallExists() {
        #expect(Router9.hasInstall(status(managed: false, external: true)))
        #expect(Router9.hasInstall(status(managed: true, external: false)))
        #expect(!Router9.hasInstall(status(managed: false, external: false)))
        #expect(!Router9.hasInstall(nil))
    }
}

/// U: status, command lines and launches against fake installs; a stub server started and stopped.
@Suite(.timeLimit(.minutes(1))) struct Router9ServiceTests {
    private static func temporaryProfile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "alethe-router9-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stub(external: String? = nil, node: String? = nil, portInUse: Bool = false,
                             version: String? = "0.5.40") -> Router9Dependencies {
        Router9Dependencies(resolveExternal: { external }, resolveNode: { node }, probeVersion: { _ in version },
                            isPortInUse: { _ in portInUse }, searchDirectories: { [] })
    }

    /// An executable shell script that records its environment in the log, forks a child and waits.
    private static func writeStubServer(at url: URL) throws {
        let script = """
        #!/bin/sh
        echo "args=$* PORT=$PORT HOSTNAME=$HOSTNAME BASE=$NEXT_PUBLIC_BASE_URL DATA_DIR=${DATA_DIR-unset} PWD=$(pwd)"
        sleep 300 &
        wait
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func writeManagedInstall(in paths: Router9Paths, version: String) throws {
        let package = paths.entryScript.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"name":"9router","version":"\#(version)"}"#.write(
            to: package.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "// stub".write(to: paths.entryScript, atomically: true, encoding: .utf8)
    }

    private static func waitForLog(_ paths: Router9Paths, containing text: String) async -> String {
        for _ in 0..<100 {
            if let log = try? String(contentsOf: paths.logFile, encoding: .utf8), log.contains(text) { return log }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? ""
    }

    private static func isAlive(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }

    @Test func pathsLiveInTheProfile() {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/p/profiles/default", directoryHint: .isDirectory))
        #expect(paths.installDirectory.path == "/p/profiles/default/tools/9router")
        #expect(paths.dataDirectory.path == "/p/profiles/default/tools/9router-data")
        #expect(paths.logFile.path == "/p/profiles/default/9router.log")
        #expect(paths.entryScript.path == "/p/profiles/default/tools/9router/node_modules/9router/cli.js")
    }

    @Test func statusReadsAFakeManagedInstall() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub(external: "/opt/bin/9router"))
        try Self.writeManagedInstall(in: service.paths, version: "0.5.59")

        let status = await service.status(port: 31000)
        #expect(status.managed == Router9Install(installed: true, version: "0.5.59", path: nil))
        #expect(status.external == Router9Install(installed: true, version: "0.5.40", path: "/opt/bin/9router"))
        #expect(!status.running)
        #expect(!status.portInUse)
        #expect(status.port == 31000)
        #expect(status.dashboardURL == "http://127.0.0.1:31000/dashboard")
        #expect(status.pinnedVersion == "0.5.59")
        #expect(status.logPath == service.paths.logFile.path(percentEncoded: false))
    }

    @Test func statusWithoutAnyInstall() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub(portInUse: true))
        let status = await service.status(port: 0)
        #expect(status.managed == .none)
        #expect(status.external == .none)
        #expect(status.portInUse)
        #expect(status.port == 20128)
        #expect(!Router9.hasInstall(status))
    }

    @Test func aManifestWithoutAVersionIsNotAnInstall() throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let paths = Router9Paths(profileDirectory: profile)
        try Self.writeManagedInstall(in: paths, version: "")
        #expect(paths.installedVersion() == nil)
    }

    @Test func commandLinesQuoteThePrefixAndPinTheVersion() {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/Users/me/Library/Application Support/Alethe/profiles/it's",
                                                       directoryHint: .isDirectory))
        #expect(Router9Commands.install(paths)
            == #"npm install --prefix '/Users/me/Library/Application Support/Alethe/profiles/it'\''s/tools/9router' 9router@0.5.59"#)
        #expect(Router9Commands.uninstall(paths)
            == #"npm uninstall --prefix '/Users/me/Library/Application Support/Alethe/profiles/it'\''s/tools/9router' 9router"#)
        #expect(Router9Commands.shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func installCommandCreatesThePrivatePrefix() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub())
        let command = try await service.installCommand()
        #expect(command.hasSuffix("9router@0.5.59"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: service.paths.installDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func managedLaunchRunsCliJsWithItsOwnDataDirectory() throws {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/p", directoryHint: .isDirectory))
        let launch = try Router9Launch.make(source: .managed, port: 31000, paths: paths, entryScriptExists: true,
                                            node: "/opt/homebrew/bin/node", external: "/x/9router")
        #expect(launch.executable == "/opt/homebrew/bin/node")
        #expect(launch.arguments == ["/p/tools/9router/node_modules/9router/cli.js"])
        #expect(launch.directory == "/p/tools/9router")
        #expect(launch.environment == [
            "DATA_DIR": "/p/tools/9router-data",
            "PORT": "31000",
            "NEXT_PUBLIC_BASE_URL": "http://127.0.0.1:31000",
            "HOSTNAME": "127.0.0.1",
        ])
    }

    @Test func externalLaunchKeepsTheUsersOwnData() throws {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/p", directoryHint: .isDirectory))
        let launch = try Router9Launch.make(source: .external, port: 0, paths: paths, entryScriptExists: false,
                                            node: nil, external: "/usr/local/bin/9router")
        #expect(launch.executable == "/usr/local/bin/9router")
        #expect(launch.arguments.isEmpty)
        #expect(launch.environment["DATA_DIR"] == nil)
        #expect(launch.environment["PORT"] == "20128")
        #expect(launch.environment["HOSTNAME"] == "127.0.0.1")
    }

    @Test func launchRefusesMissingInstallsAndNode() {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/p", directoryHint: .isDirectory))
        #expect(throws: Router9Error.notInstalled) {
            try Router9Launch.make(source: .managed, port: 1, paths: paths, entryScriptExists: false, node: "/n", external: nil)
        }
        #expect(throws: Router9Error.nodeNotFound) {
            try Router9Launch.make(source: .managed, port: 1, paths: paths, entryScriptExists: true, node: nil, external: nil)
        }
        #expect(throws: Router9Error.notInstalled) {
            try Router9Launch.make(source: .external, port: 1, paths: paths, entryScriptExists: true, node: "/n", external: nil)
        }
    }

    @Test func aBusyPortIsRefused() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let server = profile.appending(path: "9router")
        try Self.writeStubServer(at: server)
        let service = Router9Service(profileDirectory: profile,
                                     dependencies: Self.stub(external: server.path, portInUse: true))
        await #expect(throws: Router9Error.portInUse) { try await service.start(source: .external) }
        #expect(!service.isRunning)
    }

    @Test func aStubServerStartsLogsAndStopsWithNoProcessLeft() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let server = profile.appending(path: "9router")
        try Self.writeStubServer(at: server)
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub(external: server.path))

        try await service.start(port: 31000, source: .external)
        let pid = try #require(service.processID)
        #expect(getpgid(pid) == pid, "9router leads its own process group")
        let log = await Self.waitForLog(service.paths, containing: "PORT=")
        #expect(log.contains("PORT=31000 HOSTNAME=127.0.0.1 BASE=http://127.0.0.1:31000 DATA_DIR=unset"))

        // A second start while it runs is a no-op.
        try await service.start(port: 31000, source: .external)
        #expect(service.processID == pid)
        #expect(await service.status(port: 31000).running)

        var tree: [pid_t] = []
        for _ in 0..<40 {
            tree = ProcessTable.descendants(of: pid, parents: ProcessTable.parents())
            if tree.count > 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(tree.count > 1, "the stub forks a child")

        await service.stop()
        #expect(!service.isRunning)
        #expect(service.processID == nil)
        for member in tree { #expect(!Self.isAlive(member), "pid \(member) left running") }
    }

    @Test func theManagedCopyRunsFromItsInstallFolderWithItsDataDirectory() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let node = profile.appending(path: "node")
        try Self.writeStubServer(at: node)
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub(node: node.path))
        try Self.writeManagedInstall(in: service.paths, version: "0.5.59")

        try await service.start(source: .managed)
        let log = await Self.waitForLog(service.paths, containing: "DATA_DIR=")
        // Paths are passed without a directory URL's trailing slash.
        #expect(log.contains("args=\(service.paths.entryScript.path) "))
        #expect(log.contains("DATA_DIR=\(service.paths.dataDirectory.path) "))
        #expect(log.contains("PWD=\(service.paths.installDirectory.path)\n"))
        #expect(FileManager.default.fileExists(atPath: service.paths.dataDirectory.path))

        service.stopNow()
        #expect(!service.isRunning)
    }

    @Test func stopWithNothingRunningIsANoOp() async throws {
        let profile = try Self.temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let service = Router9Service(profileDirectory: profile, dependencies: Self.stub())
        await service.stop()
        service.stopNow()
        #expect(!service.isRunning)
    }

    @Test func thePortProbeSeesALoopbackListener() throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && Darwin.listen(listener, 1) == 0
                    && getsockname(listener, $0, &length) == 0
            }
        }
        try #require(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(Router9PortProbe.isInUse(port))
        #expect(!Router9PortProbe.isInUse(0), "an unbindable port is never probed")
    }
}
