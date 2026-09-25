import Darwin
import Foundation
import Synchronization
import AletheIntegrations

public enum WorkerWriteError: Error, Hashable, Sendable {
    /// The worker's stdin is closed (it exited, or it was terminated).
    case closed
    case failed(errno: Int32)
}

/// Writes JSON lines to one worker's stdin, in the order they were sent, on that worker's own queue
/// (upstream `stage_rpc` + `send_rpc`). A worker that stops reading fills its pipe and blocks only
/// this queue: never the core, never another worker. The pipe never raises SIGPIPE; a write to a
/// worker that is gone fails with `closed`.
public final class WorkerLineWriter: Sendable {
    private let queue: DispatchQueue
    /// nil once closed.
    private let descriptor: Mutex<Int32?>

    init(descriptor: Int32, label: String) {
        self.descriptor = Mutex(descriptor)
        self.queue = DispatchQueue(label: "com.kc1t.alethe.orchestrator.stdin.\(label)")
    }

    deinit {
        if let fd = descriptor.withLock({ $0 }) { Darwin.close(fd) }
    }

    /// Queues one line and returns at once.
    public func send(_ message: OrderedJSON) {
        let data = Self.line(message)
        queue.async { [self] in _ = write(data) }
    }

    /// Queues one line and waits until it is in the pipe (or failed). The wait is off the caller's
    /// isolation: a full pipe suspends the caller, it never blocks a thread the caller owns.
    public func sendAndWait(_ message: OrderedJSON) async throws(WorkerWriteError) {
        let data = Self.line(message)
        let result: Result<Void, WorkerWriteError> = await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: write(data)) }
        }
        try result.get()
    }

    /// Closes stdin after every line already queued (the worker then sees EOF).
    public func close() {
        queue.async { [self] in
            if let fd = descriptor.withLock({ current -> Int32? in defer { current = nil }; return current }) {
                Darwin.close(fd)
            }
        }
    }

    public var isClosed: Bool { descriptor.withLock { $0 == nil } }

    static func line(_ message: OrderedJSON) -> [UInt8] {
        Array((message.compactRendered() + "\n").utf8)
    }

    /// Runs on `queue` only, so lines never interleave. The descriptor stays open while a write is in
    /// flight: `close()` is queued behind it.
    private func write(_ bytes: [UInt8]) -> Result<Void, WorkerWriteError> {
        guard let fd = descriptor.withLock({ $0 }) else { return .failure(.closed) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                let code = errno
                return .failure(code == EPIPE || code == EBADF ? .closed : .failed(errno: code))
            }
        }
        return .success(())
    }
}
