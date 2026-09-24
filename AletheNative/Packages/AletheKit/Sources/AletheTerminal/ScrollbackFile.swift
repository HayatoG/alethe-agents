import Foundation

/// A terminal's output on disk, so it survives relaunch (upstream `pty.rs`: `push_scrollback`,
/// `load_scrollback`, `append_and_maybe_compact`). Output is appended in batches at most every
/// `flushInterval`; once the file passes twice the cap it is compacted to its last `cap` bytes, so
/// writes stay appends and a busy terminal never rewrites its whole history per batch.
///
/// Every file operation runs on one private serial queue; callers never block on disk except
/// `flush()`, which waits for pending bytes (quit).
public final class ScrollbackFile: @unchecked Sendable {
    public static let cap = 4 * 1024 * 1024
    public static let flushInterval: Duration = .milliseconds(250)

    public let url: URL
    private let cap: Int
    private let flushInterval: Duration
    private let queue = DispatchQueue(label: "alethe.scrollback", qos: .utility)
    private var pending = Data()
    private var flushScheduled = false

    public init(url: URL, cap: Int = ScrollbackFile.cap, flushInterval: Duration = ScrollbackFile.flushInterval) {
        self.url = url
        self.cap = cap
        self.flushInterval = flushInterval
    }

    /// The last `cap` bytes on disk (nothing when there is no file).
    public func load() -> Data {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return Data() }
            return data.count > cap ? data.suffix(cap) : data
        }
    }

    /// Queues output; written within `flushInterval`.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            pending.append(data)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + flushInterval.timeInterval) { [self] in writePending() }
        }
    }

    /// Writes pending bytes now and waits for them (quit).
    public func flush() {
        queue.sync { writePending() }
    }

    /// Empties the file (Clear Scrollback, restart).
    public func clear() {
        queue.async { [self] in
            pending.removeAll()
            try? Data().write(to: url, options: .atomic)
        }
    }

    /// Removes the file (the tab was closed).
    public func delete() {
        queue.async { [self] in
            pending.removeAll()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writePending() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), (try? handle.write(contentsOf: bytes)) != nil else { return }
        if Int(end) + bytes.count > cap * 2 { compact() }
    }

    private func compact() {
        guard let data = try? Data(contentsOf: url), data.count > cap else { return }
        try? data.suffix(cap).write(to: url, options: .atomic)
    }

    /// Sequences that undo what a dead program left on: alternate screen, mouse reporting,
    /// bracketed paste, hidden cursor, colors. Written after a replay, before the new process
    /// draws, so a restored TUI's modes do not leak into the fresh shell or agent.
    public static let replayReset = Data(
        "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[0m\r\n".utf8)
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
