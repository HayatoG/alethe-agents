import Foundation

/// A saved copy of `graph.json` in `.alethe/graph-snapshots/<ms>.json` (upstream `SnapshotInfo`).
public struct GraphSnapshot: Hashable, Sendable, Identifiable {
    /// The creation time in milliseconds, as text: the file's stem.
    public var id: String
    public var url: URL
    public var createdAt: Date
    public var sizeBytes: Int

    public var createdMilliseconds: Int64 { Int64(id) ?? 0 }
}

/// The Graphify files of one repository (port of the file side of upstream `graphify.rs`). Blocking:
/// callers run it off the main thread (`GraphifyService` does). The snapshot folder and file names
/// match the Tauri app's, so its snapshots stay listed.
public struct GraphifyRepository: Sendable {
    public let root: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root.standardizedFileURL
        self.now = now
    }

    public static let outputFolder = "graphify-out"
    public static let graphFile = "graph.json"

    public var graphURL: URL { root.appending(path: Self.outputFolder).appending(path: Self.graphFile) }
    public var snapshotsFolder: URL { root.appending(path: ".alethe").appending(path: "graph-snapshots") }
    public var hasGraph: Bool { FileManager.default.fileExists(atPath: graphURL.path) }

    /// The repository holding `directory`: the nearest folder with a `.git` entry (a folder, or the
    /// file a linked worktree has), like `git rev-parse --show-toplevel`; nil outside a repository.
    public static func repositoryRoot(containing directory: URL) -> URL? {
        // Walks path components rather than `deletingLastPathComponent()`, which turns `/` into
        // `/..`, `/../..`, … so a loop waiting for the parent to equal the child never ends.
        var components = directory.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let current = URL(filePath: NSString.path(withComponents: components), directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) { return current }
            components.removeLast()
        }
        return nil
    }

    /// Upstream `graphify_read_graph`.
    public func readGraph(limit: Int = GraphData.visualizationLimit) throws -> GraphData {
        try GraphData.parse(graphData(), limit: limit)
    }

    /// Copies the current graph into a new snapshot (upstream `graphify_snapshot`). Two snapshots in
    /// the same millisecond get consecutive ids instead of overwriting each other.
    @discardableResult
    public func snapshot() throws -> GraphSnapshot {
        let data = try graphData()
        let manager = FileManager.default
        try manager.createDirectory(at: snapshotsFolder, withIntermediateDirectories: true)
        var milliseconds = Int64((now().timeIntervalSince1970 * 1000).rounded())
        while manager.fileExists(atPath: snapshotURL(String(milliseconds)).path) { milliseconds += 1 }
        let url = snapshotURL(String(milliseconds))
        try data.write(to: url, options: .atomic)
        return GraphSnapshot(id: String(milliseconds), url: url,
                             createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000), sizeBytes: data.count)
    }

    /// Newest first; files that are not `<digits>.json` are ignored (upstream `read_snapshots`).
    public func snapshots() -> [GraphSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: snapshotsFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> GraphSnapshot? in
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", Self.isSnapshotID(stem), let milliseconds = Int64(stem) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return GraphSnapshot(id: stem, url: url, createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
                                 sizeBytes: size)
        }
        .sorted { $0.createdMilliseconds > $1.createdMilliseconds }
    }

    /// From snapshot `base` to snapshot `compare`, or to the current graph when nil (upstream
    /// `graphify_diff_snapshot`).
    public func diff(base: String, compare: String? = nil) throws -> GraphDiff {
        let baseSets = try GraphIDSets.parse(Data(contentsOf: snapshotFile(base)))
        let compareData = try compare.map { try Data(contentsOf: snapshotFile($0)) } ?? graphData()
        return GraphDiff(base: baseSets, compare: try GraphIDSets.parse(compareData))
    }

    /// Puts a snapshot back as the current graph (upstream `graphify_rollback`), written atomically.
    /// The caller asks first: the current graph is replaced.
    public func rollback(to id: String) throws {
        let data = try Data(contentsOf: snapshotFile(id))
        try FileManager.default.createDirectory(at: graphURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: graphURL, options: .atomic)
    }

    /// Keeps the newest `keepLast` and, with `maxAgeDays`, drops older ones too (upstream
    /// `graphify_prune_snapshots`). Returns how many were removed.
    @discardableResult
    public func prune(keepLast: Int, maxAgeDays: Int? = nil) -> Int {
        let nowMilliseconds = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let maxAge = maxAgeDays.map { Int64($0) * 24 * 60 * 60 * 1000 }
        var removed = 0
        for (index, snapshot) in snapshots().enumerated() {
            let tooMany = index >= keepLast
            let tooOld = maxAge.map { nowMilliseconds - snapshot.createdMilliseconds > $0 } ?? false
            guard tooMany || tooOld else { continue }
            if (try? FileManager.default.removeItem(at: snapshot.url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Helpers

    private func graphData() throws -> Data {
        do {
            return try Data(contentsOf: graphURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw GraphifyError.graphNotFound
        }
    }

    private func snapshotURL(_ id: String) -> URL { snapshotsFolder.appending(path: "\(id).json") }

    /// Only digits ever become a path, so an id cannot climb out of the folder.
    static func isSnapshotID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private func snapshotFile(_ id: String) throws -> URL {
        guard Self.isSnapshotID(id) else { throw GraphifyError.invalidSnapshotID }
        let url = snapshotURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw GraphifyError.snapshotNotFound }
        return url
    }
}
