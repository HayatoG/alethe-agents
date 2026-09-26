import Foundation
import AletheIntegrations

/// The stdio framing of `alethe-orchestrator-mcp`: one JSON-RPC message per line in, one answer per
/// line out. Lines are answered concurrently, so a long `alethe_check` never holds up a `ping`;
/// answers are written whole, one at a time. Lines split on `\n` only (a raw U+2028 inside a JSON
/// string is legal and must not break a message).
public enum OrchestratorStdio {
    /// Serves until `input` ends, then returns once every pending answer is written.
    public static func serve(
        input: FileHandle,
        output: FileHandle,
        handle: @escaping @Sendable (String) async -> String?
    ) async {
        let writer = LineOutput(output)
        await withTaskGroup(of: Void.self) { group in
            var buffer = Data()
            func dispatch(_ data: Data) {
                var bytes = data
                if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
                let line = String(decoding: bytes, as: UTF8.self)
                guard !line.allSatisfy(\.isWhitespace) else { return }
                group.addTask {
                    if let reply = await handle(line) { await writer.write(reply) }
                }
            }
            do {
                for try await byte in input.bytes {
                    if byte == UInt8(ascii: "\n") {
                        dispatch(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch {}
            if !buffer.isEmpty { dispatch(buffer) }
            await group.waitForAll()
        }
    }

    /// The standalone server's handler: every line through the MCP transport over `core`, with no
    /// planner (upstream `handle_mcp_body(&core, &line, None)`).
    public static func standalone(_ core: OrchestratorCore) -> @Sendable (String) async -> String? {
        { line in await OrchestratorMCP.handle(body: line, planner: nil, handler: core) }
    }
}

/// Serializes writes so answers never interleave. A closed pipe drops the answer; the caller ignores
/// SIGPIPE.
private actor LineOutput {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ line: String) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// Standalone mode of `alethe-orchestrator-mcp` (upstream `bin/alethe-orchestrator-mcp.rs`): its own
/// core with Codex workers, so any MCP client can delegate without Alethe open. Job history is kept
/// in memory only, as upstream.
public enum OrchestratorStandalone {
    public static let codexVariable = "ALETHE_CODEX"
    public static let maxWorkersVariable = "ALETHE_MAX_WORKERS"

    public struct Setup: Sendable {
        public var configuration: OrchestratorCore.Configuration
        /// The Codex launcher's program, nil when Codex was not found.
        public var codex: URL?
    }

    public static func setup(environment: [String: String] = ProcessInfo.processInfo.environment) -> Setup {
        var launchers = WorkerLaunchers()
        let codex = resolveCodex(environment: environment)
        if let codex { launchers.set(.codexAppServer(program: codex)) }
        var configuration = OrchestratorCore.Configuration(launchers: launchers)
        if let limit = concurrencyLimit(environment: environment) { configuration.concurrencyLimit = limit }
        return Setup(configuration: configuration, codex: codex)
    }

    /// `ALETHE_CODEX` when it names an existing file, otherwise the first `codex` on `PATH`.
    static func resolveCodex(environment: [String: String]) -> URL? {
        let manager = FileManager.default
        if let explicit = environment[codexVariable], !explicit.isEmpty, manager.fileExists(atPath: explicit) {
            return URL(filePath: explicit)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(filePath: String(directory)).appending(path: "codex")
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `ALETHE_MAX_WORKERS` as a count; the core clamps it to its range.
    static func concurrencyLimit(environment: [String: String]) -> Int? {
        guard let value = environment[maxWorkersVariable]?.trimmingCharacters(in: .whitespaces),
              let limit = UInt(value)
        else { return nil }
        return Int(clamping: limit)
    }
}
