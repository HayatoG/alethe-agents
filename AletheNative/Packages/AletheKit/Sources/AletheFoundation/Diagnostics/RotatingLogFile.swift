import Foundation

/// An append-only text file capped at `maxBytes`: when full it becomes `<name>.1` (older ones shift
/// up to `<name>.<keep - 1>`, the oldest is dropped). Not synchronized; callers serialize access.
public struct RotatingLogFile: Sendable {
    public let url: URL
    public let maxBytes: Int
    /// Files kept, the live one included.
    public let keep: Int

    public init(url: URL, maxBytes: Int, keep: Int) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
    }

    public func append(_ line: String) {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maxBytes { rotate() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Every kept file, oldest first.
    public var files: [URL] {
        let archives = (1..<keep).reversed().map(archive)
        return (archives + [url]).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The contents of every kept file, oldest first.
    public func readAll() -> String {
        files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    public func removeAll() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func archive(_ index: Int) -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(index)")
    }

    private func rotate() {
        let fileManager = FileManager.default
        guard keep > 1 else {
            try? fileManager.removeItem(at: url)
            return
        }
        try? fileManager.removeItem(at: archive(keep - 1))
        for index in stride(from: keep - 2, through: 1, by: -1) where fileManager.fileExists(atPath: archive(index).path) {
            try? fileManager.moveItem(at: archive(index), to: archive(index + 1))
        }
        try? fileManager.moveItem(at: url, to: archive(1))
    }
}
