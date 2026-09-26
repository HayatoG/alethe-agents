import Foundation
import os
import AletheFoundation

/// Remote control limits (upstream `remote/mod.rs`). Every listener, request and session is held
/// to these; the transport and the API read them from here rather than keeping their own copies.
public enum RemoteLimits {
    /// The HTTP listener takes the first free port in this range; the WebSocket listener the
    /// first free one in the range shifted by one (9341…9361).
    public static let httpPorts: ClosedRange<UInt16> = 9340...9360
    public static let webSocketPorts: ClosedRange<UInt16> = 9341...9361

    public static let maxBody = 64 * 1024
    public static let maxStaticAsset = 4 * 1024 * 1024
    public static let maxRequestHead = 96 * 1024
    public static let maxMessage = 4 * 1024
    public static let maxScrollback = 512 * 1024
    public static let maxTranscriptEvents = 160
    public static let maxPreview = 120
    public static let maxDeviceName = 48

    public static let maxDevices = 4
    public static let deviceRange: ClosedRange<Int> = 1...maxDevices
    public static let maxConnections = 24

    public static let defaultSessionExpiry: TimeInterval = 60 * 60
    public static let sessionExpiryRange: ClosedRange<TimeInterval> = (5 * 60)...(24 * 60 * 60)
    public static let pairingWindow: TimeInterval = 120
    public static let pairingTokenLength = 32
    public static let sessionTokenLength = 40

    public static let socketTimeout: Duration = .seconds(20)
    public static let webSocketAuthTimeout: Duration = .seconds(10)

    public static let authFailureLimit = 10
    public static let authFailureWindow: TimeInterval = 60
    public static let authLockout: TimeInterval = 5 * 60

    /// Well above human typing pace: this bounds a leaked session token, not normal use.
    public static let messageRateLimit = 20
    public static let messageRateWindow: TimeInterval = 60

    /// The listeners turn themselves off after this long with no paired device (0 disables).
    public static let idleDisable: TimeInterval = 4 * 60 * 60

    public static let tailscaleTimeout: Duration = .seconds(3)
}

/// Remote control's OSLog category. Device ids, addresses and sizes only — never tokens or
/// message text; addresses go out `.private`.
enum RemoteLog {
    static let logger = Logger(subsystem: AppLog.subsystem, category: "remote")
}
