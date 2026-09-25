import AletheGit
import Foundation

/// FSEvents watchers on worktrees' `.planning/` folders, one per project and folder (upstream
/// `start_gsd_watcher`/`stop_gsd_watcher`). Each watcher's `events` yields once per burst of
/// changes; the consumer re-reads `PlanningGate` then.
public final class PlanningWatchers: @unchecked Sendable {
    private let lock = NSLock()
    private var watchers: [String: GitWatcher] = [:]
    private let debounce: DispatchTimeInterval

    public init(debounce: DispatchTimeInterval = .milliseconds(300)) {
        self.debounce = debounce
    }

    deinit {
        stopAll()
    }

    /// Starts watching `root`'s `.planning/` (created when missing, as upstream does) for
    /// `projectID`; returns the running watcher when there is one already.
    public func start(projectID: String, root: URL) throws -> GitWatcher {
        let folder = PlanningGate.planningFolder(of: root).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = Self.key(projectID, folder)
        return lock.withLock {
            if let running = watchers[key] { return running }
            let watcher = GitWatcher(root: folder, debounce: debounce)
            watcher.start()
            watchers[key] = watcher
            return watcher
        }
    }

    public func stop(projectID: String, root: URL) {
        let key = Self.key(projectID, PlanningGate.planningFolder(of: root).standardizedFileURL)
        let watcher = lock.withLock { watchers.removeValue(forKey: key) }
        watcher?.stop()
    }

    public func stopAll() {
        let all = lock.withLock {
            defer { watchers.removeAll() }
            return Array(watchers.values)
        }
        all.forEach { $0.stop() }
    }

    public func isWatching(projectID: String, root: URL) -> Bool {
        let key = Self.key(projectID, PlanningGate.planningFolder(of: root).standardizedFileURL)
        return lock.withLock { watchers[key] != nil }
    }

    private static func key(_ projectID: String, _ folder: URL) -> String {
        "\(projectID):\(folder.path)"
    }
}
