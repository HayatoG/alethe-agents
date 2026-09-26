import Darwin
import Foundation

/// How phones reach the Mac: the LAN address, or the Tailscale address when chosen.
public enum RemoteReachMode: String, Codable, Sendable, CaseIterable {
    case lan, tailscale
}

/// Whether a usable Tailscale address exists right now (upstream `TailscaleStatus`), so the UI can
/// disable the Tailscale reach mode instead of letting it fail closed.
public struct RemoteTailscaleStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var ip: String?

    public init(ip: String?) {
        self.available = ip != nil
        self.ip = ip
    }
}

/// Resolves the addresses the listeners bind. Injected so tests never depend on the network or on
/// a Tailscale install.
public struct RemoteHostResolver: Sendable {
    public var lanAddress: @Sendable () async -> String
    /// `nil` when Tailscale is missing, stopped or printed anything outside 100.64.0.0/10.
    public var tailscaleAddress: @Sendable () async -> String?

    public init(
        lanAddress: @escaping @Sendable () async -> String,
        tailscaleAddress: @escaping @Sendable () async -> String?
    ) {
        self.lanAddress = lanAddress
        self.tailscaleAddress = tailscaleAddress
    }

    public static let system = RemoteHostResolver(
        lanAddress: { await Task.detached { RemoteHost.localIP() }.value },
        tailscaleAddress: { await RemoteHost.tailscaleIP() }
    )

    /// The host for a reach mode. Tailscale chosen but missing resolves to `""`, which no listener
    /// can bind — it fails closed instead of falling back to the LAN or a wildcard.
    public func host(for mode: RemoteReachMode) async -> String {
        switch mode {
        case .lan: await lanAddress()
        case .tailscale: await tailscaleAddress() ?? ""
        }
    }
}

/// Host discovery (upstream `util.rs` `local_ip`, `tailscale_ip`).
public enum RemoteHost {
    /// The address of the interface that routes outward: a UDP socket "connected" to a public
    /// address (no packet is sent) reports its local end. `127.0.0.1` when there is no route.
    public static func localIP() -> String {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return "127.0.0.1" }
        defer { close(descriptor) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(80).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &remote.sin_addr)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "127.0.0.1" }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { return "127.0.0.1" }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "127.0.0.1"
        }
        let address = addressString(buffer)
        return address == "0.0.0.0" ? "127.0.0.1" : address
    }

    private static func addressString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Tailscale hands out addresses only from the CGNAT range 100.64.0.0/10; anything else the CLI
    /// prints is refused so a misbehaving binary can never widen the bind.
    public static func isTailscaleRange(_ ip: String) -> Bool {
        var address = in_addr()
        guard !ip.isEmpty, inet_pton(AF_INET, ip, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return value >> 24 == 100 && (64...127).contains((value >> 16) & 0xFF)
    }

    /// True for a literal IPv4 or IPv6 address (brackets allowed) — what a listener can bind.
    public static func isBindableAddress(_ host: String) -> Bool {
        normalizedIP(host) != nil
    }

    /// The canonical text of a literal IP address, or `nil`.
    public static func normalizedIP(_ host: String) -> String? {
        var text = host
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &v4, &buffer, socklen_t(INET_ADDRSTRLEN)).map { _ in addressString(buffer) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)).map { _ in addressString(buffer) }
        }
        return nil
    }

    /// The IP of a peer address (`1.2.3.4:5100`, `[::1]:5100` or a bare IP), for per-address limits.
    public static func peerIP(_ address: String) -> String? {
        if let direct = normalizedIP(address) { return direct }
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            return normalizedIP(String(address[address.index(after: address.startIndex)..<close]))
        }
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return normalizedIP(String(address[..<colon]))
    }

    /// This Mac's Tailscale IPv4 from `tailscale ip -4` (3 s, off main, cancelable), or `nil` —
    /// never a guess.
    public static func tailscaleIP(timeout: Duration = RemoteLimits.tailscaleTimeout) async -> String? {
        guard let executable = tailscaleExecutable() else { return nil }
        guard let output = await runCapturingOutput(executable, ["ip", "-4"], timeout: timeout) else { return nil }
        let ip = output.split(whereSeparator: \.isNewline).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        return isTailscaleRange(ip) ? ip : nil
    }

    public static func tailscaleStatus() async -> RemoteTailscaleStatus {
        RemoteTailscaleStatus(ip: await tailscaleIP())
    }

    /// The `tailscale` CLI: on PATH, in the usual Homebrew/installer folders, or `Tailscale.app`'s
    /// bundled binary (which acts as the CLI when given arguments).
    static func tailscaleExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let pathFolders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = (pathFolders + ["/opt/homebrew/bin", "/usr/local/bin"]).map { "\($0)/tailscale" }
            + ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// Standard output of a short command, or `nil` on launch failure, non-zero exit, timeout or
    /// cancellation. The process is terminated when either passes.
    static func runCapturingOutput(_ executable: URL, _ arguments: [String], timeout: Duration) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = await withTaskCancellationHandler {
            let reader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let watchdog = Task.detached {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled, process.isRunning { process.terminate() }
            }
            let data = await reader.value
            await Task.detached { process.waitUntilExit() }.value
            watchdog.cancel()
            return data
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard !Task.isCancelled, process.terminationReason == .exit, process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: output, as: UTF8.self)
    }
}
