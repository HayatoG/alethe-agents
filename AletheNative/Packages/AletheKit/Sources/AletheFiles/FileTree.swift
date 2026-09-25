import AletheGit
import Foundation
import Observation

/// One entry of a directory listing (upstream `DirectoryEntry`).
public struct FileNode: Hashable, Sendable, Identifiable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    /// Byte size for regular files; `nil` for directories.
    public var size: Int?

    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, size: Int? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }

    public var iconName: String {
        isDirectory ? FileIcons.folderSymbol : FileIcons.symbolName(forFileName: name)
    }

    public var paneKind: FilePaneKind? {
        isDirectory ? nil : FilePaneKind.forFile(url.path)
    }
}

/// Which entries a listing shows. Upstream lists everything (dotfiles, `.git`, `node_modules`);
/// the default here matches that and only drops Finder metadata, which never appears on Windows.
public struct FileTreeFilter: Hashable, Sendable {
    public var showDotfiles: Bool
    public var hiddenNames: Set<String>

    public init(showDotfiles: Bool = true, hiddenNames: Set<String> = [".DS_Store"]) {
        self.showDotfiles = showDotfiles
        self.hiddenNames = hiddenNames
    }

    public static let `default` = FileTreeFilter()

    public func includes(_ name: String) -> Bool {
        if hiddenNames.contains(name) { return false }
        if !showDotfiles, name.hasPrefix(".") { return false }
        return true
    }
}

/// A visible row of the flattened tree.
public struct FileTreeRow: Hashable, Sendable, Identifiable {
    public var node: FileNode
    public var depth: Int
    public var isExpanded: Bool
    public var id: URL { node.url }
}

/// Lazily loaded file tree: a directory's children are read only when it is expanded, and
/// `reload()` re-reads the root and every expanded directory (e.g. on a watcher signal).
@MainActor
@Observable
public final class FileTree {
    public let root: URL
    public var filter: FileTreeFilter
    public private(set) var expanded: Set<URL> = []
    /// Loaded listings keyed by directory URL; the root is always loaded after `reload()`.
    public private(set) var listings: [URL: [FileNode]] = [:]
    public var gitBadges: GitBadgeIndex?

    public init(root: URL, filter: FileTreeFilter = .default) {
        self.root = root.standardizedFileURL
        self.filter = filter
    }

    public var rootNodes: [FileNode] { listings[root] ?? [] }

    public func children(of directory: URL) -> [FileNode]? {
        listings[directory.standardizedFileURL]
    }

    public func isExpanded(_ directory: URL) -> Bool {
        expanded.contains(directory.standardizedFileURL)
    }

    public func expand(_ directory: URL) throws {
        let key = directory.standardizedFileURL
        if listings[key] == nil {
            listings[key] = try Self.list(key, filter: filter)
        }
        expanded.insert(key)
    }

    public func collapse(_ directory: URL) {
        expanded.remove(directory.standardizedFileURL)
    }

    public func toggle(_ directory: URL) throws {
        if isExpanded(directory) { collapse(directory) } else { try expand(directory) }
    }

    /// Re-reads the root and expanded directories; directories that vanished are dropped.
    /// Cached listings of collapsed directories are discarded so they reload on the next expand.
    public func reload() throws {
        var fresh: [URL: [FileNode]] = [root: try Self.list(root, filter: filter)]
        var keep: Set<URL> = []
        for directory in expanded {
            guard let nodes = try? Self.list(directory, filter: filter) else { continue }
            fresh[directory] = nodes
            keep.insert(directory)
        }
        listings = fresh
        expanded = keep
    }

    /// Depth-first rows under expanded directories, in display order.
    public func visibleRows() -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func walk(_ directory: URL, depth: Int) {
            for node in listings[directory] ?? [] {
                let open = node.isDirectory && expanded.contains(node.url)
                rows.append(FileTreeRow(node: node, depth: depth, isExpanded: open))
                if open { walk(node.url, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    public func badge(for node: FileNode) -> GitBadge? {
        gitBadges?.badge(for: node.url, isDirectory: node.isDirectory)
    }

    /// Reloads on every (debounced) watcher signal until the stream ends or the task is cancelled.
    public func follow(_ changes: AsyncStream<Void>) async {
        for await _ in changes {
            try? reload()
        }
    }

    /// Lists one directory, sorted folders first then case-insensitively by name (upstream order).
    public nonisolated static func list(_ directory: URL, filter: FileTreeFilter = .default) throws -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        let nodes = urls.compactMap { url -> FileNode? in
            let name = url.lastPathComponent
            guard filter.includes(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            return FileNode(
                url: url.standardizedFileURL, name: name, isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize
            )
        }
        return sort(nodes)
    }

    public nonisolated static func sort(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let left = a.name.lowercased(), right = b.name.lowercased()
            return left == right ? a.name < b.name : left < right
        }
    }
}

/// FSEvents watcher for a tree root, debounced; one signal per burst of changes.
/// Reuses `GitWatcher`, which already skips `.git` object-store and lock-file noise.
public typealias FileTreeWatcher = GitWatcher
