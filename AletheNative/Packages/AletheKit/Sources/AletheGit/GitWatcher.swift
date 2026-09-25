import CoreServices
import Foundation

/// Watches a repository (worktree and `.git`) with FSEvents and yields one refresh signal per burst
/// of changes, after `debounce` of quiet. Object-store writes and lock files are ignored.
public final class GitWatcher: @unchecked Sendable {
    public let root: URL
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "com.kc1t.alethe.git-watcher")
    private let debounce: DispatchTimeInterval
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(root: URL, debounce: DispatchTimeInterval = .milliseconds(300)) {
        self.root = root.standardizedFileURL
        self.debounce = debounce
        (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        stop()
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<GitWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.received(Array(list.prefix(count)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(
                nil, callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        let work = { [self] in
            pending?.cancel()
            pending = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
        continuation.finish()
    }

    private static let queueKey = DispatchSpecificKey<Void>()

    /// Called on `queue`.
    private func received(_ paths: [String]) {
        guard paths.contains(where: { !Self.isNoise($0) }) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [continuation] in continuation.yield() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    static func isNoise(_ path: String) -> Bool {
        path.contains("/.git/objects/") || path.hasSuffix(".lock") || path.contains("/.git/logs/")
    }
}
