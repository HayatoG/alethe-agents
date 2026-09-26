import Darwin
import Foundation

/// A finished external CLI call.
public struct ExternalCommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ExternalCommandError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(Duration)
    case cancelled
}

/// Runs an external CLI (`opencode`, `graphify`, `npx`, …) with a timeout; the process and every
/// process it started are killed when the timeout passes or the calling task is cancelled.
///
/// Nothing blocks a Swift-concurrency thread: output arrives through readability handlers and the
/// exit through the termination handler, so a timeout still fires while the cooperative pool is
/// busy (blocking reads there once starved the watchdog and let `sleep 30` run to completion).
public enum ExternalCommand {
    /// How long EOF is awaited after exit: a grandchild holding a pipe open must not hang the call.
    static let pipeGrace: TimeInterval = 1

    public static func run(
        _ executable: URL,
        _ arguments: [String],
        directory: URL? = nil,
        timeout: Duration,
        discardingStderr: Bool = false
    ) async throws(ExternalCommandError) -> ExternalCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            process.currentDirectoryURL = directory
        }
        // npm-installed CLIs start with `#!/usr/bin/env node`: their own folder leads PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = discardingStderr ? FileHandle.nullDevice : stderr
        process.standardInput = FileHandle.nullDevice

        let run = CommandRun(process: process, openPipes: discardingStderr ? 1 : 2)
        let outcome: CommandRun.Outcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandRun.Outcome, Error>) in
                    // Cancelled before launch: nothing is started.
                    guard run.install(continuation) else { return }
                    stdout.fileHandleForReading.readabilityHandler = { handle in
                        run.receive(handle.availableData, stderr: false, handle: handle)
                    }
                    if !discardingStderr {
                        stderr.fileHandleForReading.readabilityHandler = { handle in
                            run.receive(handle.availableData, stderr: true, handle: handle)
                        }
                    }
                    process.terminationHandler = { _ in run.exited() }
                    do {
                        try process.run()
                    } catch {
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        run.fail(ExternalCommandError.launchFailed(error.localizedDescription))
                        return
                    }
                    run.startWatchdog(after: timeout)
                }
            } onCancel: {
                run.cancel()
            }
        } catch let error as ExternalCommandError {
            throw error
        } catch {
            throw .cancelled
        }
        switch outcome {
        case .finished(let result): return result
        case .timedOut: throw .timedOut(timeout)
        case .cancelled: throw .cancelled
        }
    }

    /// Collects one process's output; resumes once it exited and its pipes hit EOF (or shortly after
    /// exit when a grandchild keeps them open), or right away on timeout or cancellation.
    private final class CommandRun: @unchecked Sendable {
        enum Outcome: Sendable {
            case finished(ExternalCommandResult)
            case timedOut
            case cancelled
        }

        private let lock = NSLock()
        private let process: Process
        private var continuation: CheckedContinuation<Outcome, Error>?
        private var stdout = Data(), stderr = Data()
        private var openPipes: Int
        private var didExit = false
        private var stopReason: Outcome?
        private var cancelledEarly = false
        private var watchdog: DispatchWorkItem?

        init(process: Process, openPipes: Int) {
            self.process = process
            self.openPipes = openPipes
        }

        func install(_ continuation: CheckedContinuation<Outcome, Error>) -> Bool {
            lock.lock()
            let early = cancelledEarly
            if !early { self.continuation = continuation }
            lock.unlock()
            if early { continuation.resume(returning: .cancelled) }
            return !early
        }

        func startWatchdog(after timeout: Duration) {
            let item = DispatchWorkItem { [self] in stop(.timedOut) }
            lock.lock()
            watchdog = item
            let stopped = stopReason != nil
            lock.unlock()
            // Cancelled while launching: the stop found nothing running yet.
            if stopped { killTree(); return }
            let (seconds, attoseconds) = timeout.components
            let nanoseconds = max(0, seconds) * 1_000_000_000 + attoseconds / 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds)), execute: item)
        }

        func receive(_ data: Data, stderr isStderr: Bool, handle: FileHandle) {
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
                openPipes -= 1
            } else if isStderr {
                stderr.append(data)
            } else {
                stdout.append(data)
            }
            let done = openPipes <= 0 && didExit
            lock.unlock()
            if done { complete() }
        }

        func exited() {
            lock.lock()
            didExit = true
            let done = openPipes <= 0
            lock.unlock()
            if done {
                complete()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + ExternalCommand.pipeGrace) { [self] in complete() }
            }
        }

        func cancel() {
            lock.lock()
            let installed = continuation != nil
            if !installed { cancelledEarly = true }
            lock.unlock()
            stop(.cancelled)
        }

        func fail(_ error: ExternalCommandError) {
            lock.lock()
            let pending = continuation
            continuation = nil
            watchdog?.cancel()
            lock.unlock()
            pending?.resume(throwing: error)
        }

        /// Kills the process tree and reports `reason` without waiting for the pipes.
        private func stop(_ reason: Outcome) {
            lock.lock()
            guard stopReason == nil, continuation != nil || cancelledEarly else { lock.unlock(); return }
            stopReason = reason
            lock.unlock()
            killTree()
            resume(reason)
        }

        private func killTree() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            let tree = ProcessTable.descendants(of: pid, parents: ProcessTable.parents())
            // Children first, then the process itself; `Process` reaps it (termination handler).
            for member in tree.reversed() where member != pid { Darwin.kill(member, SIGKILL) }
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }

        private func complete() {
            lock.lock()
            let result = ExternalCommandResult(
                status: process.isRunning ? -1 : process.terminationStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
            let reason = stopReason
            lock.unlock()
            resume(reason ?? .finished(result))
        }

        private func resume(_ outcome: Outcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            watchdog?.cancel()
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }
}

public extension ExternalCommandResult {
    init(exitCode: Int32, stdout: String, stderr: String) {
        self.init(status: exitCode, stdout: stdout, stderr: stderr)
    }

    var exitCode: Int32 { status }
}

public extension ExternalCommand {
    /// Path form, for callers that resolved the CLI to a path string.
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                    timeout: Duration) async throws(ExternalCommandError) -> ExternalCommandResult {
        try await run(URL(filePath: executable), arguments, directory: directory, timeout: timeout)
    }
}
