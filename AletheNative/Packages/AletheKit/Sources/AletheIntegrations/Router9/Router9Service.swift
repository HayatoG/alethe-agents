import AletheAgents
import Foundation
import Synchronization

public enum Router9Error: Error, Equatable, Sendable {
    case notInstalled
    case nodeNotFound
    case portInUse
    case fileSystem(String)
    case spawnFailed(String)
    case cancelled
}

/// Where 9router lives inside one profile (upstream `install_dir`, `data_dir`, `log_path`).
public struct Router9Paths: Hashable, Sendable {
    public var profileDirectory: URL

    public init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
    }

    /// The private npm prefix of the managed copy: never the global npm tree.
    public var installDirectory: URL {
        profileDirectory.appending(path: "tools", directoryHint: .isDirectory)
            .appending(path: Router9.package, directoryHint: .isDirectory)
    }

    /// The managed copy's `DATA_DIR`, so it never shares state with a user-maintained install.
    public var dataDirectory: URL {
        profileDirectory.appending(path: "tools", directoryHint: .isDirectory)
            .appending(path: "9router-data", directoryHint: .isDirectory)
    }

    public var logFile: URL { profileDirectory.appending(path: "9router.log", directoryHint: .notDirectory) }

    var packageDirectory: URL {
        installDirectory.appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: Router9.package, directoryHint: .isDirectory)
    }

    public var entryScript: URL { packageDirectory.appending(path: "cli.js", directoryHint: .notDirectory) }

    /// The managed copy's version from its `package.json`; nil when it is not installed.
    public func installedVersion() -> String? {
        let manifest = packageDirectory.appending(path: "package.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: manifest),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty else { return nil }
        return version
    }
}

/// The exact command lines the install sheet runs through the login shell (P3-3). Built only here,
/// so the pinned version and the private prefix have a single source of truth.
public enum Router9Commands {
    public static func install(_ paths: Router9Paths) -> String {
        "npm install --prefix \(shellQuoted(paths.installDirectory.plainPath)) "
            + "\(Router9.package)@\(Router9.pinnedVersion)"
    }

    public static func uninstall(_ paths: Router9Paths) -> String {
        "npm uninstall --prefix \(shellQuoted(paths.installDirectory.plainPath)) \(Router9.package)"
    }

    /// POSIX single quoting: the path reaches npm as one argument whatever it contains.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What a start runs: resolved before spawning so it is testable without a process.
public struct Router9Launch: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String?
    /// Variables added on top of the app's environment.
    public var environment: [String: String]

    /// Upstream `router9_start`. `PORT`, `NEXT_PUBLIC_BASE_URL` and `HOSTNAME=127.0.0.1` always:
    /// 9router serves a Next.js app, which binds every interface unless `HOSTNAME` says otherwise.
    static func make(source: Router9Source, port: Int, paths: Router9Paths, entryScriptExists: Bool,
                     node: String?, external: String?) throws(Router9Error) -> Router9Launch {
        var launch: Router9Launch
        switch source {
        case .managed:
            guard entryScriptExists else { throw .notInstalled }
            guard let node else { throw .nodeNotFound }
            launch = Router9Launch(executable: node, arguments: [paths.entryScript.plainPath],
                                   directory: paths.installDirectory.plainPath,
                                   environment: ["DATA_DIR": paths.dataDirectory.plainPath])
        case .external:
            guard let external else { throw .notInstalled }
            // No DATA_DIR: the user's own install keeps its own configuration.
            launch = Router9Launch(executable: external, arguments: [], directory: nil, environment: [:])
        }
        let port = Router9.normalizePort(port)
        launch.environment["PORT"] = String(port)
        launch.environment["NEXT_PUBLIC_BASE_URL"] = Router9.baseURL(port: port)
        launch.environment["HOSTNAME"] = "127.0.0.1"
        return launch
    }
}

/// The system calls the service makes, replaceable in tests.
public struct Router9Dependencies: Sendable {
    /// Path of a user-installed `9router`, or nil.
    public var resolveExternal: @Sendable () -> String?
    /// Path of `node` for the managed copy, or nil.
    public var resolveNode: @Sendable () -> String?
    public var probeVersion: @Sendable (String) async -> String?
    /// Whether something answers on the loopback port (400 ms probe).
    public var isPortInUse: @Sendable (Int) async -> Bool
    /// Directories added to the child's PATH (a Finder-launched app has a minimal one).
    public var searchDirectories: @Sendable () -> [String]

    public init(resolveExternal: @escaping @Sendable () -> String?,
                resolveNode: @escaping @Sendable () -> String?,
                probeVersion: @escaping @Sendable (String) async -> String?,
                isPortInUse: @escaping @Sendable (Int) async -> Bool,
                searchDirectories: @escaping @Sendable () -> [String]) {
        self.resolveExternal = resolveExternal
        self.resolveNode = resolveNode
        self.probeVersion = probeVersion
        self.isPortInUse = isPortInUse
        self.searchDirectories = searchDirectories
    }

    public static func live(launchers: LauncherCache = LauncherCache()) -> Router9Dependencies {
        Router9Dependencies(
            resolveExternal: { launchers.resolve(Router9.package) },
            resolveNode: { launchers.resolve("node") },
            probeVersion: { await CLIVersion.probe($0) },
            isPortInUse: { port in
                await Task.detached { Router9PortProbe.isInUse(port) }.value
            },
            searchDirectories: { launchers.searchDirectories }
        )
    }
}

/// 9router (upstream `router9.rs`): status, start and stop of one local proxy per profile. Nothing
/// here runs on its own; every call is an explicit user action. The API key is not needed to run it
/// and never passes through here.
public actor Router9Service {
    public nonisolated let paths: Router9Paths
    private let dependencies: Router9Dependencies
    private let slot = Mutex<Router9Process?>(nil)

    public init(profileDirectory: URL, dependencies: Router9Dependencies = .live()) {
        self.paths = Router9Paths(profileDirectory: profileDirectory)
        self.dependencies = dependencies
    }

    /// The process this app started is still alive. Safe from any thread.
    public nonisolated var isRunning: Bool { runningProcess() != nil }

    /// Pid of the running process group leader, for diagnostics and tests.
    public nonisolated var processID: Int32? { runningProcess()?.pid }

    private nonisolated func runningProcess() -> Router9Process? {
        slot.withLock { current in
            guard let process = current else { return nil }
            if process.isRunning { return process }
            current = nil
            return nil
        }
    }

    public func status(port: Int = Router9.defaultPort) async -> Router9Status {
        let port = Router9.normalizePort(port)
        let paths = paths, dependencies = dependencies
        async let managedVersion = Task.detached { paths.installedVersion() }.value
        async let portInUse = dependencies.isPortInUse(port)
        async let external = Self.externalInstall(dependencies)
        return Router9Status(
            managed: await managedVersion.map { Router9Install(installed: true, version: $0) } ?? .none,
            external: await external,
            running: isRunning,
            portInUse: await portInUse,
            port: port,
            installDirectory: paths.installDirectory.plainPath,
            dataDirectory: paths.dataDirectory.plainPath,
            logPath: paths.logFile.plainPath,
            dashboardURL: Router9.dashboardURL(port: port)
        )
    }

    private static func externalInstall(_ dependencies: Router9Dependencies) async -> Router9Install {
        guard let path = dependencies.resolveExternal() else { return .none }
        return Router9Install(installed: true, version: await dependencies.probeVersion(path), path: path)
    }

    /// The install command line; creates the private prefix first, as upstream does.
    public func installCommand() throws(Router9Error) -> String {
        do {
            try FileManager.default.createDirectory(at: paths.installDirectory, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem(error.localizedDescription)
        }
        return Router9Commands.install(paths)
    }

    public nonisolated func uninstallCommand() -> String { Router9Commands.uninstall(paths) }

    /// Starts 9router on `port` from `source`. A no-op while it already runs; a port another process
    /// holds is refused. Output is appended to the profile's `9router.log`.
    public func start(port: Int = Router9.defaultPort, source: Router9Source = .managed) async throws(Router9Error) {
        if isRunning { return }
        let port = Router9.normalizePort(port)
        if await dependencies.isPortInUse(port) { throw .portInUse }
        if Task.isCancelled { throw .cancelled }
        // A concurrent start may have won while the port was probed.
        if isRunning { return }

        let paths = paths
        let entryExists = FileManager.default.isReadableFile(atPath: paths.entryScript.plainPath)
        let launch = try Router9Launch.make(
            source: source, port: port, paths: paths, entryScriptExists: entryExists,
            node: source == .managed ? dependencies.resolveNode() : nil,
            external: source == .external ? dependencies.resolveExternal() : nil)
        do {
            try FileManager.default.createDirectory(at: paths.logFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if source == .managed {
                try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            }
        } catch {
            throw .fileSystem(error.localizedDescription)
        }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, added in added }
        // The inherited PWD names Alethe's own folder; a launch that changes directory updates it, as
        // a shell would, so `pwd` and Node's `process.env.PWD` report the install folder.
        if let directory = launch.directory { environment["PWD"] = directory }
        // npm CLIs start with `#!/usr/bin/env node`: the executable's folder and the usual install
        // roots lead PATH.
        let executableDirectory = (launch.executable as NSString).deletingLastPathComponent
        environment["PATH"] = ([executableDirectory] + dependencies.searchDirectories()
            + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")

        let process = try Router9Process.spawn(launch.executable, arguments: launch.arguments,
                                               directory: launch.directory, environment: environment,
                                               logFile: paths.logFile.plainPath)
        slot.withLock { $0 = process }
    }

    /// Terminates the process group and reaps it; a no-op when nothing runs.
    public func stop() async {
        guard let process = slot.withLock({ current -> Router9Process? in
            defer { current = nil }
            return current
        }) else { return }
        // `terminate` blocks up to its grace period: keep it off the cooperative pool.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.terminate()
                continuation.resume()
            }
        }
    }

    /// Synchronous teardown for app exit (upstream `stop_managed`). Blocks up to the grace period.
    public nonisolated func stopNow() {
        slot.withLock { current -> Router9Process? in
            defer { current = nil }
            return current
        }?.terminate()
    }
}

private extension URL {
    /// The file-system path without percent-encoding and without the trailing slash a directory URL
    /// carries (`/p/tools/9router`, not `/p/tools/9router/`): the form npm, `DATA_DIR` and the
    /// working directory are given.
    var plainPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
