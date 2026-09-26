import Darwin
import Foundation
import Network

enum RemoteSocketError: Error {
    case closed
    case timedOut
}

/// Async access to one accepted `NWConnection`. Every operation that can wait on the peer takes a
/// timeout; a timeout or task cancellation cancels the connection, which ends any pending I/O.
final class RemoteSocket: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// The peer as `ip:port` (`[ip]:port` for IPv6).
    var peerAddress: String { Self.address(of: connection.endpoint) }

    /// Starts the connection; false when it fails, is cancelled or is not ready within `timeout`.
    func start(timeout: Duration) async -> Bool {
        let resumed = OnceFlag()
        let ready: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.claim() { continuation.resume(returning: true) }
                    case .failed, .cancelled:
                        if resumed.claim() { continuation.resume(returning: false) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [connection] in
                    if resumed.claim() {
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        return ready
    }

    /// Bytes as they arrive (TCP); `complete` once the peer closed its side.
    func receive(maximumLength: Int, timeout: Duration) async throws -> (data: Data?, complete: Bool) {
        try await withDeadline(timeout) { connection, continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
                if let error, data == nil {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }

    /// One WebSocket message: its opcode and payload. `nil` when the peer closed.
    func receiveMessage() async throws -> (opcode: NWProtocolWebSocket.Opcode, data: Data)? {
        try await withDeadline(nil) { connection, continuation in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                guard let metadata else {
                    // No WebSocket metadata: the connection ended.
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (metadata.opcode, data ?? Data()))
            }
        }
    }

    func send(_ data: Data, timeout: Duration) async throws {
        try await send(data, context: .defaultMessage, timeout: timeout)
    }

    func sendText(_ text: String, timeout: Duration) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await send(Data(text.utf8), context: context, timeout: timeout)
    }

    private func send(_ data: Data, context: NWConnection.ContentContext, timeout: Duration) async throws {
        let _: Void = try await withDeadline(timeout) { connection, continuation in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    /// Closes a plain TCP connection once pending sends are flushed.
    func close() {
        guard markClosed() else { return }
        connection.cancel()
    }

    /// Sends a WebSocket close frame, then cancels; forced after a short grace period so a peer
    /// that stopped reading cannot hold the socket open.
    func closeWebSocket(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) {
        guard markClosed() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 2) { [connection] in
            if connection.state != .cancelled { connection.forceCancel() }
        }
    }

    /// Cancels at once (remote control stopping).
    func cancel() {
        _ = markClosed()
        connection.forceCancel()
    }

    private func markClosed() -> Bool {
        lock.withLock {
            defer { closed = true }
            return !closed
        }
    }

    /// Runs one callback-based operation; the connection is cancelled when `timeout` passes or the
    /// task is cancelled first, which makes Network.framework complete the callback with an error.
    private func withDeadline<Value: Sendable>(
        _ timeout: Duration?,
        _ operation: @escaping @Sendable (NWConnection, CheckedContinuation<Value, any Error>) -> Void
    ) async throws -> Value {
        let finished = OnceFlag()
        let connection = connection
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if finished.claim() { connection.cancel() }
            }
        }
        defer { _ = finished.claim() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation(connection, continuation)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "Unknown device" }
        switch host {
        case .ipv4(let address):
            return "\(text(of: address.rawValue, family: AF_INET) ?? "\(address)"):\(port.rawValue)"
        case .ipv6(let address):
            return "[\(text(of: address.rawValue, family: AF_INET6) ?? "\(address)")]:\(port.rawValue)"
        case .name(let name, _):
            return "\(name):\(port.rawValue)"
        @unknown default:
            return "Unknown device"
        }
    }

    private static func text(of raw: Data, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = raw.withUnsafeBytes { bytes in
            inet_ntop(family, bytes.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard converted else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// True for the first `claim()` only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
