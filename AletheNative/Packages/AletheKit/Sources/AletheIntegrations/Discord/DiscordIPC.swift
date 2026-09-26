import Darwin
import Foundation

// Port of upstream `discord_presence.rs` and the parts of the `discord-rich-presence` crate (1.1.0) it
// uses: Discord's local IPC socket, its framing and the handshake / SET_ACTIVITY payloads.

/// What Alethe shows on the user's Discord profile.
public struct DiscordActivity: Hashable, Sendable {
    public var details: String
    public var state: String
    /// Unix time in seconds (upstream `STARTED_AT`).
    public var startedAt: Int64

    public init(details: String, state: String, startedAt: Int64) {
        self.details = details
        self.state = state
        self.startedAt = startedAt
    }
}

/// The surface the app's presence controller talks to; tests substitute a fake.
public protocol DiscordPresenceClient: Sendable {
    /// Returns whether Discord received the activity. Never throws: no Discord is a normal state.
    @discardableResult func setActivity(_ activity: DiscordActivity) async -> Bool
    /// Clears the activity and closes the connection, when there is one.
    func clearActivity() async
}

public enum DiscordIPC {
    public static let applicationID = "1517303547761528942"
    static let largeImageAsset = "alethe"
    static let largeText = "Alethe"
    static let socketCount = 10
    /// Environment keys the crate searches, in order (only `TMPDIR` is set on macOS).
    static let environmentKeys = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
    /// A handshake reply is small; anything larger is not Discord.
    static let maxFrameLength: UInt32 = 1 << 20

    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    struct Frame: Equatable {
        var opcode: UInt32
        var payload: Data
    }

    /// Opcode and payload length as little-endian UInt32s, then the JSON bytes.
    static func frame(opcode: Opcode, payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Opcode and payload length from an 8-byte header.
    static func parseHeader(_ header: Data) -> (opcode: UInt32, length: UInt32)? {
        guard header.count == 8 else { return nil }
        let bytes = [UInt8](header)
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }
        return (word(0), word(4))
    }

    // serde_json without `preserve_order` writes object keys sorted, compact, with unescaped slashes.
    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    static func handshakePayload(clientID: String) -> Data {
        json(["v": 1, "client_id": clientID])
    }

    static func activityPayload(_ activity: DiscordActivity, pid: Int32, nonce: String) -> Data {
        let body: [String: Any] = [
            "details": activity.details,
            "state": activity.state,
            "timestamps": ["start": activity.startedAt],
            "assets": ["large_image": largeImageAsset, "large_text": largeText],
        ]
        return json(["cmd": "SET_ACTIVITY", "args": ["pid": pid, "activity": body], "nonce": nonce])
    }

    static func clearPayload(pid: Int32, nonce: String) -> Data {
        json(["cmd": "SET_ACTIVITY", "args": ["pid": pid, "activity": NSNull()], "nonce": nonce])
    }

    static let closePayload = Data("{}".utf8)

    /// The directories Discord may have put its socket in, from the process environment.
    public static func defaultSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var seen = Set<String>()
        return environmentKeys.compactMap { environment[$0] }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `discord-ipc-0…9` in each directory, in the crate's order.
    static func candidatePaths(in directories: [String]) -> [String] {
        directories.flatMap { directory in
            (0..<socketCount).map { (directory as NSString).appendingPathComponent("discord-ipc-\($0)") }
        }
    }
}

/// Blocking POSIX socket helpers. Every socket has send and receive timeouts and never raises SIGPIPE.
enum DiscordIPCSocket {
    static let ioTimeoutSeconds = 2

    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Runs `body` with a `sockaddr_un` for `path`; nil when the path does not fit.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(path: String) -> Int32? {
        guard let fd = makeSocket() else { return nil }
        let result = withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    static func readExact(_ fd: Int32, count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { return nil }
            offset += received
        }
        return Data(buffer)
    }

    static func readFrame(_ fd: Int32) -> DiscordIPC.Frame? {
        guard let header = readExact(fd, count: 8),
              let (opcode, length) = DiscordIPC.parseHeader(header),
              length <= DiscordIPC.maxFrameLength
        else { return nil }
        guard length > 0 else { return DiscordIPC.Frame(opcode: opcode, payload: Data()) }
        guard let payload = readExact(fd, count: Int(length)) else { return nil }
        return DiscordIPC.Frame(opcode: opcode, payload: payload)
    }

    /// Discards replies Discord queued since the last send. False when Discord hung up.
    static func drain(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
            if received > 0 { continue }
            if received == 0 { return false }
            return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
        }
    }
}

/// Discord Rich Presence over the local IPC socket. Runs on its own serial queue (never the main thread
/// or the cooperative pool, since socket calls block up to their timeout). Does nothing and stays
/// silent while Discord is not running; connection attempts back off after a failure.
public actor DiscordIPCClient: DiscordPresenceClient {
    public struct Backoff: Sendable {
        public var initial: TimeInterval
        public var maximum: TimeInterval

        public init(initial: TimeInterval = 2, maximum: TimeInterval = 60) {
            self.initial = initial
            self.maximum = maximum
        }
    }

    private let queue = DispatchSerialQueue(label: "com.kc1t.alethe.discord-ipc")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let applicationID: String
    private let searchDirectories: [String]
    private let backoff: Backoff
    private let now: @Sendable () -> TimeInterval
    private let pid: Int32

    private var socket: Int32?
    private var nextConnectAttempt: TimeInterval = 0
    private var currentDelay: TimeInterval

    public init(
        applicationID: String = DiscordIPC.applicationID,
        searchDirectories: [String] = DiscordIPC.defaultSearchDirectories(),
        backoff: Backoff = Backoff(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.applicationID = applicationID
        self.searchDirectories = searchDirectories
        self.backoff = backoff
        self.now = now
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.currentDelay = backoff.initial
    }

    deinit {
        if let socket { Darwin.close(socket) }
    }

    public var isConnected: Bool { socket != nil }

    @discardableResult
    public func setActivity(_ activity: DiscordActivity) async -> Bool {
        guard !Task.isCancelled else { return false }
        let payload = { DiscordIPC.activityPayload(activity, pid: self.pid, nonce: Self.nonce()) }
        if socket == nil {
            connectIfDue()
            // Discord not running, or still inside the backoff window: stay silent.
            guard socket != nil else { return false }
        }
        if send(.frame, payload()) { return true }
        // Upstream reconnects once when a send fails (e.g. Discord restarted), regardless of backoff.
        disconnect()
        guard !Task.isCancelled else { return false }
        connect()
        if send(.frame, payload()) { return true }
        disconnect()
        return false
    }

    public func clearActivity() async {
        guard socket != nil else { return }
        _ = send(.frame, DiscordIPC.clearPayload(pid: pid, nonce: Self.nonce()))
        close()
    }

    /// The crate's `close`: a CLOSE frame, then the socket is shut down.
    private func close() {
        guard let socket else { return }
        _ = DiscordIPCSocket.writeAll(socket, DiscordIPC.frame(opcode: .close, payload: DiscordIPC.closePayload))
        shutdown(socket, SHUT_RDWR)
        disconnect()
    }

    private func disconnect() {
        if let socket { Darwin.close(socket) }
        socket = nil
    }

    private func connectIfDue() {
        guard now() >= nextConnectAttempt else { return }
        connect()
    }

    private func connect() {
        disconnect()
        let fileManager = FileManager.default
        for path in DiscordIPC.candidatePaths(in: searchDirectories) where fileManager.fileExists(atPath: path) {
            guard !Task.isCancelled else { return }
            guard let fd = DiscordIPCSocket.connect(path: path) else { continue }
            if handshake(fd) {
                socket = fd
                currentDelay = backoff.initial
                nextConnectAttempt = 0
                return
            }
            Darwin.close(fd)
        }
        nextConnectAttempt = now() + currentDelay
        currentDelay = min(currentDelay * 2, backoff.maximum)
    }

    private func handshake(_ fd: Int32) -> Bool {
        let hello = DiscordIPC.frame(opcode: .handshake, payload: DiscordIPC.handshakePayload(clientID: applicationID))
        guard DiscordIPCSocket.writeAll(fd, hello), let reply = DiscordIPCSocket.readFrame(fd) else { return false }
        // Discord answers READY on a FRAME; a CLOSE carries a rejection (e.g. an unknown application id).
        return reply.opcode != DiscordIPC.Opcode.close.rawValue
    }

    private func send(_ opcode: DiscordIPC.Opcode, _ payload: Data) -> Bool {
        guard let socket, DiscordIPCSocket.drain(socket) else { return false }
        return DiscordIPCSocket.writeAll(socket, DiscordIPC.frame(opcode: opcode, payload: payload))
    }

    private static func nonce() -> String { UUID().uuidString.lowercased() }
}
