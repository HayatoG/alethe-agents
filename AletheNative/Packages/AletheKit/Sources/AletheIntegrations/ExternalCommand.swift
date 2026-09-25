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

/// Runs an external CLI (`opencode`, `graphify`, `npx`, …) off the main thread with a timeout; the
/// process is terminated when the timeout passes or the calling task is cancelled.
public enum ExternalCommand {
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        directory: URL? = nil,
        timeout: Duration
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
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let timedOut = Flag()
        do {
            try process.run()
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
        let result = await withTaskCancellationHandler {
            let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            let watchdog = Task.detached {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            let outData = await out.value
            let errData = await err.value
            await Task.detached { process.waitUntilExit() }.value
            watchdog.cancel()
            return ExternalCommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if Task.isCancelled { throw .cancelled }
        if timedOut.isSet { throw .timedOut(timeout) }
        return result
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
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
