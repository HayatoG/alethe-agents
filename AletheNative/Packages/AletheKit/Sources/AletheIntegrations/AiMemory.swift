import Darwin
import Foundation

/// What detection found for the `ai-memory` CLI (upstream `AiMemoryStatus`).
public struct AiMemoryStatus: Equatable, Sendable {
    /// The executable probed; nil when none was found on disk.
    public var executable: String?
    /// `--version` ran and exited 0.
    public var installed: Bool
    /// The loopback endpoint accepts connections.
    public var running: Bool
    public var version: String?

    public init(executable: String?, installed: Bool, running: Bool, version: String?) {
        self.executable = executable
        self.installed = installed
        self.running = running
        self.version = version
    }
}

/// The MCP server an agent launch gets for ai-memory.
public struct AiMemoryServer: Equatable, Sendable {
    public var name: String
    public var command: String
    public var arguments: [String]
}

/// Port of upstream `ai_memory.rs`: detection and the `ai-memory mcp` stdio server that Claude Code,
/// Codex and OpenCode launches get while the aiMemory feature is on.
public enum AiMemory {
    public static let defaultCommand = "ai-memory"
    /// Key under `mcpServers` / `mcp_servers` (upstream `MCP_KEY`).
    public static let serverName = "ai-memory"
    /// The server's health endpoint (upstream `DEFAULT_ENDPOINT`); only "running" is derived from it.
    public static let endpointHost = "127.0.0.1"
    public static let endpointPort: UInt16 = 49374
    public static var endpoint: String { "\(endpointHost):\(endpointPort)" }
    public static let documentation = URL(string: "https://github.com/akitaonrails/ai-memory")!

    /// The trimmed `--version` output when the CLI exited 0 (upstream keeps stdout as is, e.g.
    /// "ai-memory 0.9.2"); nil for a failure or an empty answer.
    public static func parseVersion(output: String, exitCode: Int32) -> String? {
        guard exitCode == 0 else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether `--version` counts as installed: upstream only needs a zero exit.
    public static func isInstalled(exitCode: Int32?) -> Bool { exitCode == 0 }

    /// The server for one launch: only with the feature on and an executable on disk, and not when
    /// detection of that same executable already found it broken (a launch before detection finishes
    /// is still wired, as the CLI is there).
    public static func server(enabled: Bool, executable: String?, status: AiMemoryStatus?) -> AiMemoryServer? {
        guard enabled, let executable, !executable.isEmpty else { return nil }
        if let status, status.executable == executable, !status.installed { return nil }
        return AiMemoryServer(name: serverName, command: executable, arguments: ["mcp"])
    }

    /// Runs `--version` and checks the endpoint, off the caller's thread; both are bounded by
    /// `timeout`. A nil `executable` reports not installed without running anything.
    public static func detect(executable: String?, timeout: Duration = .seconds(5),
                              endpointTimeout: Duration = .milliseconds(250)) async -> AiMemoryStatus {
        async let running = LoopbackProbe.isListening(host: endpointHost, port: endpointPort, timeout: endpointTimeout)
        guard let executable else {
            return AiMemoryStatus(executable: nil, installed: false, running: await running, version: nil)
        }
        let result = await ShortCommand.run(executable, ["--version"], timeout: timeout)
        let exitCode = result?.exitCode
        return AiMemoryStatus(
            executable: executable,
            installed: isInstalled(exitCode: exitCode),
            running: await running,
            version: result.flatMap { parseVersion(output: $0.output, exitCode: $0.exitCode) }
        )
    }
}

/// A short CLI call: stdout and the exit code, nil when it cannot start. Killed past `timeout`
/// (a killed call reports the signal's non-zero status) or when the calling task is cancelled.
enum ShortCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: Duration) async -> (output: String, exitCode: Int32)? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // npm-installed CLIs start with `#!/usr/bin/env node`; their own folder leads PATH.
        let folder = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = folder + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        return await withTaskCancellationHandler {
            let text = await Task.detached {
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }.value
            process.waitUntilExit()
            watchdog.cancel()
            return (text, process.terminationStatus)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Whether something accepts TCP connections on an IPv4 loopback port (upstream `endpoint_alive`).
enum LoopbackProbe {
    static func isListening(host: String, port: UInt16, timeout: Duration) async -> Bool {
        await Task.detached { connects(host: host, port: port, timeout: timeout) }.value
    }

    private static func connects(host: String, port: UInt16, timeout: Duration) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
        guard poll(&descriptor, 1, max(milliseconds, 1)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
