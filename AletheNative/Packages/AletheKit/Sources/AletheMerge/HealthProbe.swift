import Foundation

/// Outcome of booting the project's start command in the merge environment (upstream `HealthProbeResult`).
/// A warning signal only: it never blocks a merge.
public struct HealthProbeResult: Codable, Equatable, Sendable {
    public var started: Bool
    public var responded: Bool
    public var statusCode: Int?
    public var elapsedMs: Int
    public var outputTail: String
    /// `nil` when the app is not an Alethe core; the terminal round-trip is not ported (see P4-12 notes).
    public var terminalVerified: Bool?

    public init(started: Bool, responded: Bool, statusCode: Int?, elapsedMs: Int, outputTail: String, terminalVerified: Bool? = nil) {
        self.started = started
        self.responded = responded
        self.statusCode = statusCode
        self.elapsedMs = elapsedMs
        self.outputTail = outputTail
        self.terminalVerified = terminalVerified
    }

    /// Any HTTP answer counts as "responded" upstream; a 2xx/3xx is additionally healthy.
    public var healthy: Bool { responded && (statusCode.map { (200..<400).contains($0) } ?? false) }
}

public enum HealthProbeError: Error, Equatable, Sendable {
    case environmentNotFound
    case spawnFailed(String)
}

/// Port of upstream `health_probe`: runs `sh -c <start>` with `PORT` set to a free port, polls
/// `http://127.0.0.1:<port><path>` until it answers, the process exits or the timeout elapses, then
/// always terminates the process.
public struct HealthProbe: Sendable {
    public static let maxOutputTail = 8 * 1024

    public var shell: URL
    public init(shell: URL = URL(fileURLWithPath: "/bin/sh")) { self.shell = shell }

    // MARK: Pure helpers

    /// `http://127.0.0.1:<port>` plus `path`, defaulting to `/` and adding a missing leading slash.
    public static func probeURL(port: Int, path: String?) -> URL? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        return URL(string: "http://127.0.0.1:\(port)\(normalized)")
    }

    /// Keeps the last `limit` bytes of `text` (upstream `append_capped`), on a character boundary.
    public static func capped(_ text: String, limit: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        var index = utf8.index(utf8.endIndex, offsetBy: -limit)
        while index < utf8.endIndex, String.Index(index, within: text) == nil { index = utf8.index(after: index) }
        return String(text[index...])
    }

    /// Whether an `/api/health` body identifies an Alethe core (`service: "alethe-core"`).
    public static func isAletheCore(healthBody data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["service"] as? String == "alethe-core"
    }

    /// Timeout floor matches upstream (`timeout_ms.max(1000)`).
    public static func effectiveTimeout(ms: Int) -> Int { max(ms, 1000) }

    // MARK: Run

    public func run(in directory: URL, startCommand: String, path: String?, timeoutMs: Int = 8000) async throws -> HealthProbeResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw HealthProbeError.environmentNotFound
        }
        let start = Date()
        let port = try Self.freePort()
        let buffer = OutputBuffer()

        let process = Process()
        process.executableURL = shell
        process.arguments = ["-c", startCommand]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do { try process.run() } catch { throw HealthProbeError.spawnFailed(error.localizedDescription) }
        defer {
            if process.isRunning {
                process.terminate()
            }
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        var responded = false
        var status: Int?
        if let url = Self.probeURL(port: port, path: path) {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)
            let deadline = start.addingTimeInterval(Double(Self.effectiveTimeout(ms: timeoutMs)) / 1000)
            while Date() < deadline, !Task.isCancelled {
                if let (_, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse {
                    responded = true
                    status = http.statusCode
                    break
                }
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            session.invalidateAndCancel()
        }
        return HealthProbeResult(
            started: true, responded: responded, statusCode: status,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000),
            outputTail: Self.capped(buffer.text, limit: Self.maxOutputTail))
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HealthProbeError.spawnFailed("socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        guard bound else { throw HealthProbeError.spawnFailed("bind") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > HealthProbe.maxOutputTail * 2 { data.removeFirst(data.count - HealthProbe.maxOutputTail) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
