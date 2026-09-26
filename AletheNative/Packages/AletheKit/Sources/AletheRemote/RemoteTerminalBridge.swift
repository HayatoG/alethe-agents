import Foundation

/// What happened when remote input was written to a tab.
public enum RemoteWriteOutcome: Equatable, Sendable {
    case written
    /// The tab exists but has no live process (the API answers 409).
    case notRunning
    case notFound
}

/// Output of a running tab, raw, as the app's terminal tap saw it.
public enum RemoteTerminalChunk: Equatable, Sendable {
    case data(terminalID: String, bytes: Data)
    /// `reason` is upstream's: `exited`, `killed`, `suspended` or `restarted`.
    case exit(terminalID: String, reason: String)
}

/// The app's terminals as remote control reads them (upstream `pty_bridge.rs`): the app supplies the
/// lookups by tab id, the bridge turns them into a `RemoteTerminalSource` — typed input, the
/// scrollback tail cut on a character boundary, the grid size and live output decoded as UTF-8 even
/// when a character is split across chunks.
public struct RemoteTerminalBridge: RemoteTerminalSource {
    public struct Backend: Sendable {
        /// Writes bytes to the tab's PTY as typed input.
        public var write: @Sendable (_ terminalID: String, _ bytes: Data) async -> RemoteWriteOutcome
        /// The tab's grid; nil when it runs nothing.
        public var size: @Sendable (_ terminalID: String) async -> RemoteTerminalSize?
        /// At most the last `maxBytes` bytes of the tab's saved output.
        public var scrollback: @Sendable (_ terminalID: String, _ maxBytes: Int) async -> Data
        /// Starts delivering every running tab's output to `handler` (on any thread); the returned
        /// closure stops it.
        public var observe: @Sendable (_ handler: @escaping @Sendable (RemoteTerminalChunk) -> Void) -> @Sendable () -> Void

        public init(
            write: @escaping @Sendable (String, Data) async -> RemoteWriteOutcome,
            size: @escaping @Sendable (String) async -> RemoteTerminalSize?,
            scrollback: @escaping @Sendable (String, Int) async -> Data,
            observe: @escaping @Sendable (@escaping @Sendable (RemoteTerminalChunk) -> Void) -> @Sendable () -> Void
        ) {
            self.write = write
            self.size = size
            self.scrollback = scrollback
            self.observe = observe
        }
    }

    /// Output chunks buffered for a slow consumer before the oldest are dropped.
    static let outputBuffer = 4_096

    private let backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    public func scrollbackTail(terminalID: String, maxBytes: Int) async -> String {
        guard maxBytes > 0 else { return "" }
        let data = await backend.scrollback(terminalID, maxBytes)
        return Self.tail(data, maxBytes: maxBytes)
    }

    public func size(terminalID: String) async -> RemoteTerminalSize? {
        await backend.size(terminalID)
    }

    public func write(terminalID: String, text: String) async throws(RemoteInputError) {
        switch await backend.write(terminalID, Data(text.utf8)) {
        case .written: return
        case .notRunning: throw .notRunning
        case .notFound: throw .notFound
        }
    }

    public func output() -> AsyncStream<RemoteTerminalOutput> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteTerminalOutput.self, bufferingPolicy: .bufferingNewest(Self.outputBuffer))
        let decoder = RemoteOutputDecoder()
        let stop = backend.observe { chunk in
            if let output = decoder.decode(chunk) { continuation.yield(output) }
        }
        continuation.onTermination = { _ in stop() }
        return stream
    }

    /// The last `maxBytes` of `data` as text, starting on a UTF-8 character boundary (upstream
    /// `align_to_char_boundary`); invalid bytes become U+FFFD.
    static func tail(_ data: Data, maxBytes: Int) -> String {
        var bytes = [UInt8](data.suffix(maxBytes))
        var skip = 0
        // Continuation bytes (10xxxxxx) cannot start a character; at most three precede a lead byte.
        while skip < min(3, bytes.count), bytes[skip] & 0xC0 == 0x80 { skip += 1 }
        bytes.removeFirst(skip)
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Decodes each tab's output as UTF-8, holding back a character split across chunks until its
/// last byte arrives. Thread-safe: the tap calls it from the PTY queues.
final class RemoteOutputDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: [UInt8]] = [:]

    func decode(_ chunk: RemoteTerminalChunk) -> RemoteTerminalOutput? {
        switch chunk {
        case .data(let id, let bytes):
            let text = lock.withLock { () -> String in
                var buffer = pending.removeValue(forKey: id) ?? []
                buffer.append(contentsOf: bytes)
                let cut = Self.completePrefix(buffer)
                if cut < buffer.count { pending[id] = Array(buffer[cut...]) }
                return String(decoding: buffer[..<cut], as: UTF8.self)
            }
            return text.isEmpty ? nil : .data(terminalID: id, text: text)
        case .exit(let id, let reason):
            lock.withLock { pending[id] = nil }
            return .exit(terminalID: id, reason: reason)
        }
    }

    /// How many leading bytes end on a complete character: an unfinished sequence of up to three
    /// bytes at the end is held back.
    static func completePrefix(_ bytes: [UInt8]) -> Int {
        let count = bytes.count
        var index = count - 1
        var seen = 0
        while index >= 0, seen < 3, bytes[index] & 0xC0 == 0x80 {
            index -= 1
            seen += 1
        }
        guard index >= 0 else { return count }
        let lead = bytes[index]
        let needed: Int
        switch lead {
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default: return count
        }
        return count - index < needed ? index : count
    }
}
