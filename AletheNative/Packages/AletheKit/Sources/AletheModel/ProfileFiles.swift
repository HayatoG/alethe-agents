import Foundation

/// What Settings › Profiles shows per profile (upstream `ProfileSummary`).
public struct ProfileSummary: Hashable, Sendable {
    public var projects: Int
    public var terminals: Int
    /// Bytes on disk of the profile folder, scrollback included.
    public var bytes: Int64

    public init(projects: Int = 0, terminals: Int = 0, bytes: Int64 = 0) {
        self.projects = projects
        self.terminals = terminals
        self.bytes = bytes
    }
}

/// File work on whole profile folders. Blocking: callers run it off the main thread.
public enum ProfileFiles {
    /// Counts from a `workspace.json` read loosely, so a file from another build still counts.
    public static func counts(ofWorkspaceAt url: URL) -> (projects: Int, terminals: Int) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [[String: Any]] else { return (0, 0) }
        let terminals = projects
            .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            .reduce(0) { $0 + (($1["tabs"] as? [Any])?.count ?? 0) }
        return (projects.count, terminals)
    }

    public static func summary(of id: ProfileID, in locations: DataLocations) -> ProfileSummary {
        let counts = counts(ofWorkspaceAt: locations.workspace(id))
        return ProfileSummary(projects: counts.projects, terminals: counts.terminals,
                              bytes: size(of: locations.profileDirectory(id)))
    }

    /// Allocated size of every regular file below `directory`.
    public static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Files that only matter to a running app and never travel with a profile (upstream
    /// `is_excluded_from_backup`): atomic-save leftovers, logs, the Tauri WebView cache, Finder's
    /// `.DS_Store`. `relativePath` is relative to the profile folder, `/`-separated.
    public static func isRuntimeFile(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard let first = components.first, let last = components.last else { return false }
        if first.caseInsensitiveCompare("EBWebView") == .orderedSame { return true }
        if last == ".DS_Store" { return true }
        let ext = (last as NSString).pathExtension.lowercased()
        return ext == "tmp" || ext == "log"
    }

    /// Copies `source` into `destination` (created), leaving runtime files and anything but regular
    /// files and folders (sockets, symbolic links) behind.
    public static func copyProfileFolder(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard manager.fileExists(atPath: source.path) else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: keys) else { return }
        let base = source.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            if isRuntimeFile(relativePath: relative) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let target = destination.appending(path: relative)
            if values.isDirectory == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: url, to: target)
            }
        }
    }

    /// Moves a deleted profile's folder to the Trash, so a mistaken delete can be undone from Finder.
    /// A folder that was never created is fine.
    public static func trashProfileFolder(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}
