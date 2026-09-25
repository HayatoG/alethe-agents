import AletheFoundation
import Darwin
import Foundation

/// A running shared browser.
public struct BrowserSessionInfo: Hashable, Sendable {
    public var endpoint: String
    public var port: UInt16
    public var executable: URL
    public var profileDirectory: URL
    public var processID: Int32
    public var headless: Bool
}

/// The Chromium-family browser automation tools attach to over the DevTools protocol (upstream
/// `browser_session.rs`): launched on a free loopback port with its profile inside the Alethe profile,
/// ready once `/json/version` answers, killed with its process group on stop and when a leftover of
/// an earlier run holds the profile. Concurrent starts share one launch.
public actor BrowserSession {
    public let profileDirectory: URL
    private let readyTimeout: Duration
    private let pollInterval: Duration
    private let running = RunningSlot()
    private var starting: Task<(BrowserProcess, BrowserSessionInfo), any Error>?
    /// Bumped by `stop()`, so a launch that finishes after it is discarded.
    private var stops = 0

    public init(profileDirectory: URL, readyTimeout: Duration = .seconds(20), pollInterval: Duration = .milliseconds(150)) {
        self.profileDirectory = profileDirectory
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
    }

    /// The running browser, if its process is still alive. Safe from any thread.
    public nonisolated var current: BrowserSessionInfo? { running.info() }

    /// Starts the browser, or returns the one already running. Cancelling the caller cancels the
    /// launch and kills what it started.
    public func start(executable: String? = nil, headless: Bool = false) async throws -> BrowserSessionInfo {
        if let info = running.info() { return info }
        running.take()?.terminate(grace: 0)
        let generation = stops
        let launch: Task<(BrowserProcess, BrowserSessionInfo), any Error>
        if let starting {
            launch = starting
        } else {
            let profile = profileDirectory, timeout = readyTimeout, poll = pollInterval
            launch = Task.detached {
                try await Self.launch(executable: executable, headless: headless, profile: profile,
                                      timeout: timeout, poll: poll)
            }
            starting = launch
        }
        do {
            let (process, info) = try await withTaskCancellationHandler {
                try await launch.value
            } onCancel: {
                launch.cancel()
            }
            if starting == launch { starting = nil }
            guard generation == stops else {
                process.terminate(grace: 0)
                throw CancellationError()
            }
            running.set(process, info)
            return info
        } catch {
            if starting == launch { starting = nil }
            throw error
        }
    }

    /// Stops the browser (and a launch in progress); waits until its processes are gone.
    public func stop() async {
        stops += 1
        starting?.cancel()
        starting = nil
        guard let process = running.take() else { return }
        await Task.detached { process.terminate() }.value
    }

    /// Resolve, sweep leftovers, spawn, wait for `/json/version`; anything started is killed on failure.
    private static func launch(executable: String?, headless: Bool, profile: URL, timeout: Duration,
                               poll: Duration) async throws -> (BrowserProcess, BrowserSessionInfo) {
        let binary = try BrowserLaunch.resolve(explicit: executable)
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw BrowserSessionError.profileDirectory(error.localizedDescription)
        }
        killStale(profileDirectory: profile)
        try Task.checkCancellation()
        let port = try BrowserLaunch.freePort()
        let process = try BrowserProcess.spawn(binary, arguments: BrowserLaunch.arguments(
            port: port, profileDirectory: profile, headless: headless))
        let info = BrowserSessionInfo(endpoint: BrowserLaunch.endpoint(port: port), port: port, executable: binary,
                                      profileDirectory: profile, processID: process.pid, headless: headless)
        do {
            try await waitUntilReady(info.endpoint, process: process, timeout: timeout, poll: poll)
        } catch {
            process.terminate(grace: 0)
            if !(error is CancellationError) {
                AppLog.record(.warning, .integrations, "Shared browser did not start: \(error)")
            }
            throw error
        }
        AppLog.info(.integrations, "Shared browser ready at \(info.endpoint) (\(binary.lastPathComponent))")
        return (process, info)
    }

    /// Chromium answers `/json/version` only once the debugging port is bound, so that is the signal
    /// rather than the process merely existing.
    static func waitUntilReady(_ endpoint: String, process: BrowserProcess, timeout: Duration,
                               poll: Duration) async throws {
        guard let url = URL(string: "\(endpoint)/json/version") else { throw BrowserSessionError.notReady }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw BrowserSessionError.notReady }
            if let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: poll)
        }
        throw BrowserSessionError.notReady
    }

    /// Kills browsers an earlier run left on this profile: they hold its lock, so a new browser would
    /// never bind its port. Matched by executable and exact profile argument, never by command line alone.
    public static func killStale(profileDirectory: URL) {
        let own = ProcessInfo.processInfo.processIdentifier
        for pid in ProcessTable.pids() where pid != own && pid > 1 {
            guard let command = ProcessTable.commandLine(of: pid),
                  BrowserLaunch.isStale(executable: command.executable, arguments: command.arguments,
                                        profileDirectory: profileDirectory) else { continue }
            Darwin.kill(pid, SIGKILL)
            AppLog.info(.integrations, "Killed a leftover browser (\(pid)) holding the shared profile")
        }
    }
}

/// The running process, readable without hopping onto the actor (launch wiring is synchronous).
private final class RunningSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var process: BrowserProcess?
    private var stored: BrowserSessionInfo?

    func info() -> BrowserSessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return stored
    }

    func set(_ process: BrowserProcess, _ info: BrowserSessionInfo) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        stored = info
    }

    /// Clears the slot and hands back the process to terminate (dead or alive).
    func take() -> BrowserProcess? {
        lock.lock()
        defer { lock.unlock() }
        let taken = process
        process = nil
        stored = nil
        return taken
    }
}
