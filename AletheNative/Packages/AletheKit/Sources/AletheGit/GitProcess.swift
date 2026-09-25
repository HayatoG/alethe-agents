import Foundation

public enum GitError: Error, Equatable, Sendable {
    case notARepository
    case gitMissing
    case commandFailed(exitCode: Int32, stderr: String)
    case cancelled
    /// A path, hash or branch name rejected before reaching git (argument-injection defense).
    case invalidArgument(String)
}

/// The captured result of one git invocation.
public struct GitOutput: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs the user's `git` binary off the main thread. The process is terminated when the calling task
/// is cancelled; credentials are left to git's own helpers (`GIT_TERMINAL_PROMPT=0`, no stdin).
public struct GitRunner: Sendable {
    public var executable: URL?
    public var environment: [String: String]

    public init(executable: URL? = GitRunner.locateGit(), environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }

    public static func locateGit(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs git and returns its output; a non-zero exit outside `allowedExitCodes` throws.
    /// `onProgress` receives stderr lines (split on `\r` and `\n`) as they arrive.
    public func run(
        _ arguments: [String],
        in directory: URL,
        allowedExitCodes: Set<Int32> = [0],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitOutput {
        guard let executable else { throw GitError.gitMissing }
        try Task.checkCancellation(or: .cancelled)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let state = RunState(process: process, onProgress: onProgress)
        let output: GitOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitOutput, Error>) in
                state.install(continuation)
                out.fileHandleForReading.readabilityHandler = { handle in
                    state.receive(handle.availableData, stderr: false, handle: handle)
                }
                err.fileHandleForReading.readabilityHandler = { handle in
                    state.receive(handle.availableData, stderr: true, handle: handle)
                }
                process.terminationHandler = { _ in state.terminated() }
                do {
                    try process.run()
                } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.fail(GitError.gitMissing)
                }
            }
        } onCancel: {
            state.cancel()
        }
        guard allowedExitCodes.contains(output.exitCode) else {
            let message = output.errorText
            if Self.isNotARepository(message) { throw GitError.notARepository }
            throw GitError.commandFailed(exitCode: output.exitCode, stderr: message)
        }
        return output
    }

    static func isNotARepository(_ stderr: String) -> Bool {
        stderr.lowercased().contains("not a git repository")
    }
}

extension Task where Success == Never, Failure == Never {
    static func checkCancellation(or error: GitError) throws {
        if Task.isCancelled { throw error }
    }
}

/// Collects a process's output and resumes the continuation once it exited and both pipes hit EOF.
/// A grandchild holding a pipe open (a hook, an alias) must not hang the call, so EOF is awaited
/// only briefly after exit.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let onProgress: (@Sendable (String) -> Void)?
    private var continuation: CheckedContinuation<GitOutput, Error>?
    private var stdout = Data(), stderr = Data()
    private var progressBuffer = Data()
    private var openPipes = 2
    private var exited = false
    private var cancelled = false

    init(process: Process, onProgress: (@Sendable (String) -> Void)?) {
        self.process = process
        self.onProgress = onProgress
    }

    func install(_ continuation: CheckedContinuation<GitOutput, Error>) {
        lock.lock()
        self.continuation = continuation
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { finish(throwing: GitError.cancelled) }
    }

    func receive(_ data: Data, stderr isStderr: Bool, handle: FileHandle) {
        var lines: [String] = []
        lock.lock()
        if data.isEmpty {
            handle.readabilityHandler = nil
            openPipes -= 1
        } else if isStderr {
            stderr.append(data)
            if onProgress != nil {
                progressBuffer.append(data)
                lines = Self.drainLines(&progressBuffer)
            }
        } else {
            stdout.append(data)
        }
        let done = openPipes == 0 && exited
        lock.unlock()
        if let onProgress { lines.forEach(onProgress) }
        if done { complete() }
    }

    func terminated() {
        lock.lock()
        exited = true
        let done = openPipes == 0 || cancelled
        lock.unlock()
        if done {
            complete()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in complete() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func fail(_ error: Error) { finish(throwing: error) }

    private func complete() {
        lock.lock()
        if cancelled {
            lock.unlock()
            finish(throwing: GitError.cancelled)
            return
        }
        let result = GitOutput(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }

    static func drainLines(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...index)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
