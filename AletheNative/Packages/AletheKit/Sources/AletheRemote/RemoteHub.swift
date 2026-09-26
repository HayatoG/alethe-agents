import Foundation

/// A paired device as the Settings and pairing UI list it (upstream `RemoteDeviceInfo`).
public struct RemoteDeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var address: String
    public var connectedAt: Date
    public var expiresAt: Date
    /// A WebSocket is attached.
    public var online: Bool
}

/// Remote control's state for the UI (upstream `RemoteInfo`; the QR comes from `RemotePairingQR`).
public struct RemoteInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var connectedDevices: Int
    public var onlineDevices: Int
    public var maxDevices: Int
    public var sessionExpirySecs: Int
    public var readOnly: Bool
    public var allowShellInput: Bool
    public var reachMode: RemoteReachMode
    public var pairingOpen: Bool
    public var pairingExpiresIn: Int
    public var devices: [RemoteDeviceInfo]
    public var pairingURL: String?
    public var httpURL: String?
    public var wsURL: String?
}

/// A successful pairing: the device id and its session token (sent once, to that device).
public struct RemotePairing: Equatable, Sendable {
    public var deviceID: Int
    public var sessionToken: String
}

public enum RemotePairingError: Error, Equatable, Sendable {
    case windowClosed, invalidToken, deviceLimitReached

    /// Upstream's wire message (`{"error": …}` on a 401).
    public var message: String {
        switch self {
        case .windowClosed: "Pairing window is closed"
        case .invalidToken: "Invalid pairing token"
        case .deviceLimitReached: "Maximum remote devices reached"
        }
    }
}

/// Pairing, sessions and limits for remote control (upstream `remote/state.rs`). Pure state: no
/// sockets. Tokens live here only, in memory, and are compared in constant time; they are never
/// logged.
public actor RemoteHub {
    public typealias Clock = @Sendable () -> Date

    private struct Session {
        var id: Int
        var token: String
        var name: String
        var address: String
        var connectedAt: Date
        var expiresAt: Date
        var subscription: String?
        var outbox: AsyncStream<String>.Continuation?
    }

    private struct AuthFailures {
        var count: Int
        var windowStart: Date
        var lockedUntil: Date?
    }

    private struct MessageRate {
        var count: Int
        var windowStart: Date
    }

    private let resolver: RemoteHostResolver
    private let clock: Clock

    private(set) var pairingToken = RemoteText.randomToken(length: RemoteLimits.pairingTokenLength)
    private var pairingUntil: Date?
    public private(set) var host = ""
    private var running = false
    public private(set) var generation: UInt64 = 0
    public private(set) var httpPort: UInt16 = 0
    public private(set) var wsPort: UInt16 = 0
    private var nextSessionID = 1
    public private(set) var maxDevices = 1
    public private(set) var sessionExpiry = RemoteLimits.defaultSessionExpiry
    public private(set) var isReadOnly = false
    public private(set) var shellInputAllowed = false
    public private(set) var reachMode = RemoteReachMode.lan
    private(set) var connections = 0
    private var sessions: [Session] = []
    private var failures: [String: AuthFailures] = [:]
    private var messageRates: [Int: MessageRate] = [:]
    private var lastActive: Date

    /// Events for the app (single consumer: the remote control controller).
    public nonisolated let events: AsyncStream<RemoteEvent>
    private nonisolated let eventSink: AsyncStream<RemoteEvent>.Continuation

    public init(resolver: RemoteHostResolver = .system, now: @escaping Clock = { Date() }) {
        self.resolver = resolver
        self.clock = now
        self.lastActive = now()
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteEvent.self)
        events = stream
        eventSink = continuation
    }

    public nonisolated func emit(_ event: RemoteEvent) {
        eventSink.yield(event)
    }

    // MARK: Run state

    public var isEnabled: Bool { running }

    public func isActive(generation: UInt64) -> Bool {
        running && self.generation == generation
    }

    /// Marks remote control running; returns whether it already was.
    @discardableResult
    public func beginRun() -> Bool {
        defer { running = true }
        return running
    }

    public func endRun() {
        running = false
    }

    @discardableResult
    public func nextGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    /// Starts a run (upstream `remote::start` before the listeners spawn): resolves the host and
    /// returns the generation the listeners run under, or `nil` when already running.
    public func start() async -> UInt64? {
        guard !beginRun() else { return nil }
        await refreshHost()
        touchActivity()
        return nextGeneration()
    }

    /// Stops the run (upstream `remote::stop`): listeners of the old generation wind down, every
    /// device is revoked and pairing closes.
    public func stop() {
        endRun()
        nextGeneration()
        resetPorts()
        revokeAll()
        closePairingWindow()
        RemoteLog.logger.info("remote control disabled")
    }

    public func setHTTPPort(_ port: UInt16) { httpPort = port }
    public func setWSPort(_ port: UInt16) { wsPort = port }

    public func clearHTTPPort(ifGeneration generation: UInt64) {
        if self.generation == generation { httpPort = 0 }
    }

    public func clearWSPort(ifGeneration generation: UInt64) {
        if self.generation == generation { wsPort = 0 }
    }

    public func resetPorts() {
        httpPort = 0
        wsPort = 0
    }

    // MARK: Preferences

    public func setMaxDevices(_ value: Int) {
        maxDevices = min(max(value, RemoteLimits.deviceRange.lowerBound), RemoteLimits.deviceRange.upperBound)
    }

    public func setSessionExpiry(_ seconds: TimeInterval) {
        sessionExpiry = min(max(seconds, RemoteLimits.sessionExpiryRange.lowerBound), RemoteLimits.sessionExpiryRange.upperBound)
    }

    public func setReadOnly(_ value: Bool) { isReadOnly = value }
    public func setAllowShellInput(_ value: Bool) { shellInputAllowed = value }

    /// Returns whether the mode changed — only then must running listeners rebind (upstream
    /// `remote_control_set_reach_mode`).
    @discardableResult
    public func setReachMode(_ mode: RemoteReachMode) -> Bool {
        defer { reachMode = mode }
        return reachMode != mode
    }

    // MARK: Connections

    public func tryAcquireConnection(max: Int = RemoteLimits.maxConnections) -> Bool {
        guard connections < max else { return false }
        connections += 1
        return true
    }

    public func releaseConnection() {
        connections = Swift.max(0, connections - 1)
    }

    // MARK: Host

    /// Resolves the host for the reach mode. Tailscale chosen but missing leaves `""`, which no
    /// listener can bind (fail closed).
    public func refreshHost() async {
        host = await resolver.host(for: reachMode)
    }

    // MARK: Pairing

    public func openPairingWindow() {
        pairingToken = RemoteText.randomToken(length: RemoteLimits.pairingTokenLength)
        pairingUntil = clock().addingTimeInterval(RemoteLimits.pairingWindow)
    }

    public func closePairingWindow() {
        pairingToken = RemoteText.randomToken(length: RemoteLimits.pairingTokenLength)
        pairingUntil = nil
    }

    /// Whole seconds left in the pairing window; 0 when closed or remote control is off.
    public var pairingRemaining: Int {
        guard running, let pairingUntil else { return 0 }
        return Swift.max(0, Int(pairingUntil.timeIntervalSince(clock())))
    }

    /// The URL the QR carries, while pairing is open and the HTTP listener is up.
    public var pairingURL: String? {
        guard pairingRemaining > 0, httpPort != 0 else { return nil }
        return "http://\(host):\(httpPort)/?pair=\(pairingToken)"
    }

    /// Exchanges the pairing token for a device session and closes the window.
    public func pair(token provided: String, name: String, address: String) throws(RemotePairingError) -> RemotePairing {
        guard pairingRemaining > 0 else { throw .windowClosed }
        guard RemoteText.tokensEqual(provided, pairingToken) else { throw .invalidToken }
        pruneExpired()
        guard sessions.count < maxDevices else { throw .deviceLimitReached }
        let id = nextSessionID
        nextSessionID += 1
        let token = RemoteText.randomToken(length: RemoteLimits.sessionTokenLength)
        let connectedAt = clock()
        sessions.append(Session(
            id: id,
            token: token,
            name: RemoteText.truncated(name, to: RemoteLimits.maxDeviceName),
            address: address,
            connectedAt: connectedAt,
            expiresAt: connectedAt.addingTimeInterval(sessionExpiry),
            subscription: nil,
            outbox: nil
        ))
        closePairingWindow()
        touchActivity()
        RemoteLog.logger.info("device \(id, privacy: .public) paired from \(address, privacy: .private)")
        return RemotePairing(deviceID: id, sessionToken: token)
    }

    // MARK: Info

    public func info() -> RemoteInfo {
        pruneExpired()
        let devices = sessions.map {
            RemoteDeviceInfo(
                id: $0.id, name: $0.name, address: $0.address,
                connectedAt: $0.connectedAt, expiresAt: $0.expiresAt, online: $0.outbox != nil
            )
        }
        let pairingURL = pairingURL
        return RemoteInfo(
            enabled: running,
            connectedDevices: devices.count,
            onlineDevices: devices.filter(\.online).count,
            maxDevices: maxDevices,
            sessionExpirySecs: Int(sessionExpiry),
            readOnly: isReadOnly,
            allowShellInput: shellInputAllowed,
            reachMode: reachMode,
            pairingOpen: pairingURL != nil,
            pairingExpiresIn: pairingRemaining,
            devices: devices,
            pairingURL: pairingURL,
            httpURL: httpPort != 0 ? "http://\(host):\(httpPort)" : nil,
            wsURL: wsPort != 0 ? "ws://\(host):\(wsPort)" : nil
        )
    }

    /// The `Origin` a WebSocket upgrade may carry: the HTTP listener's URL.
    public var allowedOrigin: String { "http://\(host):\(httpPort)" }

    public func connectedDeviceCount() -> Int {
        guard running else { return 0 }
        pruneExpired()
        return sessions.count
    }

    // MARK: Sessions

    /// Drops expired sessions, ending their output streams.
    public func pruneExpired() {
        let now = clock()
        sessions.removeAll { session in
            guard session.expiresAt <= now else { return false }
            session.outbox?.finish()
            messageRates[session.id] = nil
            return true
        }
    }

    public func sessionID(for token: String) -> Int? {
        guard !token.isEmpty else { return nil }
        pruneExpired()
        // Compare against every session so the time taken does not reveal which one matched.
        var match: Int?
        for session in sessions where RemoteText.tokensEqual(token, session.token) && match == nil {
            match = session.id
        }
        return match
    }

    public func sessionAlive(_ id: Int) -> Bool {
        let now = clock()
        return sessions.contains { $0.id == id && $0.expiresAt > now }
    }

    public func deviceName(_ id: Int) -> String {
        sessions.first { $0.id == id }?.name ?? "Remote device"
    }

    public func renameDevice(_ id: Int, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = RemoteText.truncated(name, to: RemoteLimits.maxDeviceName)
    }

    /// Opens the session's output stream (its WebSocket). One per session: a newer socket
    /// replaces the older one, whose stream ends. `nil` when the session is gone.
    public func attach(_ id: Int) -> AsyncStream<String>? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        sessions[index].outbox?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        sessions[index].outbox = continuation
        return stream
    }

    /// The session's socket closed: its stream ends and its subscription is dropped.
    public func detach(_ id: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].outbox?.finish()
        sessions[index].outbox = nil
        sessions[index].subscription = nil
    }

    /// The terminal the session follows (one at a time; `nil` follows none).
    public func setSubscription(_ id: Int, terminalID: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].subscription = terminalID
    }

    public func subscription(_ id: Int) -> String? {
        sessions.first { $0.id == id }?.subscription
    }

    /// Sends a frame to every live session following `terminalID`. `payload` runs only when at
    /// least one does. Returns how many sessions received it.
    @discardableResult
    public func publish(terminalID: String, payload: @Sendable () -> String) -> Int {
        let now = clock()
        let subscribed = sessions.indices.filter {
            sessions[$0].expiresAt > now && sessions[$0].outbox != nil && sessions[$0].subscription == terminalID
        }
        guard !subscribed.isEmpty else { return 0 }
        let message = payload()
        var delivered = 0
        for index in subscribed {
            guard let outbox = sessions[index].outbox else { continue }
            if case .terminated = outbox.yield(message) {
                sessions[index].outbox = nil
            } else {
                delivered += 1
            }
        }
        return delivered
    }

    public func publish(_ output: RemoteTerminalOutput) {
        publish(terminalID: output.terminalID) { output.frame }
    }

    public func revokeDevice(_ id: Int) {
        sessions.removeAll { session in
            guard session.id == id else { return false }
            session.outbox?.finish()
            return true
        }
        messageRates[id] = nil
        RemoteLog.logger.info("device \(id, privacy: .public) revoked")
    }

    public func revokeAll() {
        for session in sessions { session.outbox?.finish() }
        sessions.removeAll()
        messageRates.removeAll()
    }

    // MARK: Activity

    /// A device is using remote control; the idle check counts from the last call.
    public func touchActivity() {
        lastActive = clock()
    }

    /// True once nobody has been paired for `threshold` seconds straight (0 disables the check).
    public func isIdle(threshold: TimeInterval = RemoteLimits.idleDisable) -> Bool {
        connectedDeviceCount() == 0
            && Self.idleExpired(now: clock().timeIntervalSince1970, lastActive: lastActive.timeIntervalSince1970, threshold: threshold)
    }

    static func idleExpired(now: TimeInterval, lastActive: TimeInterval, threshold: TimeInterval) -> Bool {
        threshold > 0 && Swift.max(0, now - lastActive) >= threshold
    }

    /// Per-session input throttle (`/api/message`, answers, interrupts), separate from the
    /// auth-failure lockout: bounds how fast a paired device can send.
    public func allowMessage(_ sessionID: Int) -> Bool {
        let now = clock()
        var rate = messageRates[sessionID] ?? MessageRate(count: 0, windowStart: now)
        if now.timeIntervalSince(rate.windowStart) > RemoteLimits.messageRateWindow {
            rate = MessageRate(count: 0, windowStart: now)
        }
        rate.count += 1
        messageRates[sessionID] = rate
        return rate.count <= RemoteLimits.messageRateLimit
    }

    // MARK: Auth failures

    public func authBlocked(_ address: String) -> Bool {
        guard let ip = RemoteHost.peerIP(address), let lockedUntil = failures[ip]?.lockedUntil else { return false }
        return lockedUntil > clock()
    }

    /// Counts a failed pairing or session check; `authFailureLimit` within the window locks the
    /// address out for `authLockout`.
    public func recordAuthFailure(_ address: String) {
        guard let ip = RemoteHost.peerIP(address) else { return }
        let now = clock()
        failures = failures.filter { _, entry in
            (entry.lockedUntil.map { $0 > now } ?? false)
                || now.timeIntervalSince(entry.windowStart) <= RemoteLimits.authFailureWindow
        }
        var entry = failures[ip] ?? AuthFailures(count: 0, windowStart: now, lockedUntil: nil)
        if now.timeIntervalSince(entry.windowStart) > RemoteLimits.authFailureWindow {
            entry = AuthFailures(count: 0, windowStart: now, lockedUntil: nil)
        }
        entry.count += 1
        if entry.count >= RemoteLimits.authFailureLimit {
            entry.lockedUntil = now.addingTimeInterval(RemoteLimits.authLockout)
            RemoteLog.logger.warning("too many failed attempts from \(ip, privacy: .private); blocked for 5 minutes")
        }
        failures[ip] = entry
    }

    public func clearAuthFailures(_ address: String) {
        guard let ip = RemoteHost.peerIP(address) else { return }
        failures[ip] = nil
    }
}
