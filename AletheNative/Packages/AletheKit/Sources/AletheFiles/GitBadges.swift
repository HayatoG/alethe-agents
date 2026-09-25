import AletheGit
import Foundation

/// Git state shown next to an explorer entry (upstream `fileExplorerGit.ts`).
public enum GitBadge: String, Hashable, Sendable, CaseIterable {
    case conflict, modified, stagedModified, added, untracked, renamed, deleted

    /// Higher wins when several changes land on the same file or folder.
    public var priority: Int {
        switch self {
        case .conflict: 100
        case .modified: 80
        case .stagedModified: 70
        case .added: 60
        case .untracked: 50
        case .renamed: 40
        case .deleted: 30
        }
    }

    public var letter: String {
        switch self {
        case .conflict: "!"
        case .modified, .stagedModified: "M"
        case .added: "A"
        case .untracked: "U"
        case .renamed: "R"
        case .deleted: "D"
        }
    }
}

/// File and folder badges for one repository; folders aggregate the strongest child badge.
/// Keys are repo-relative, case-insensitive paths (as upstream).
public struct GitBadgeIndex: Hashable, Sendable {
    public let repoRoot: String
    public private(set) var files: [String: GitBadge] = [:]
    public private(set) var folders: [String: GitBadge] = [:]

    public init(status: GitStatus, repoRoot: URL) {
        self.repoRoot = Self.normalize(repoRoot)
        for entry in status.entries {
            guard let badge = Self.badge(for: entry) else { continue }
            register(entry.path, badge)
        }
    }

    static func badge(for entry: GitStatusEntry) -> GitBadge? {
        switch entry.kind {
        case .ignored: return nil
        case .unmerged: return .conflict
        case .untracked: return .untracked
        case .ordinary, .renamed:
            // Staged and unstaged sides both count; the stronger one wins (as upstream).
            let staged: GitBadge? = switch entry.index {
            case .added?: .added
            case .deleted?: .deleted
            case .renamed?, .copied?: .renamed
            case nil: nil
            default: .stagedModified
            }
            let unstaged: GitBadge? = switch entry.worktree {
            case .deleted?: .deleted
            case .renamed?, .copied?: .renamed
            case nil: nil
            default: .modified
            }
            return [staged, unstaged].compactMap { $0 }.max { $0.priority < $1.priority }
        }
    }

    private mutating func register(_ path: String, _ badge: GitBadge) {
        var key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        while key.hasPrefix("/") { key.removeFirst() }
        while key.hasSuffix("/") { key.removeLast() } // untracked directories end with "/"
        if files[key].map({ badge.priority > $0.priority }) ?? true { files[key] = badge }
        var parts = key.split(separator: "/").dropLast()
        folders[""] = Self.stronger(folders[""], badge)
        while !parts.isEmpty {
            let folder = parts.joined(separator: "/")
            folders[folder] = Self.stronger(folders[folder], badge)
            parts = parts.dropLast()
        }
        if path.hasSuffix("/") { folders[key] = Self.stronger(folders[key], badge) }
    }

    private static func stronger(_ current: GitBadge?, _ new: GitBadge) -> GitBadge {
        guard let current else { return new }
        return new.priority > current.priority ? new : current
    }

    static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func badge(for url: URL, isDirectory: Bool) -> GitBadge? {
        let path = Self.normalize(url)
        if path == repoRoot { return isDirectory ? folders[""] : nil }
        guard path.hasPrefix(repoRoot + "/") else { return nil }
        let relative = String(path.dropFirst(repoRoot.count + 1))
        return isDirectory ? folders[relative] : files[relative]
    }
}
