import AletheGit
import Foundation

/// A status split the way Git Control lists it: conflicts, staged, and unstaged plus untracked.
/// An entry changed in both the index and the worktree appears in staged and unstaged.
public struct GitChangeGroups: Equatable, Sendable {
    public var conflicts: [GitStatusEntry]
    public var staged: [GitStatusEntry]
    public var unstaged: [GitStatusEntry]

    public init(_ status: GitStatus?) {
        let entries = status?.entries ?? []
        conflicts = entries.filter(\.isConflict)
        staged = entries.filter(\.isStaged)
        unstaged = entries.filter { $0.isUnstaged || $0.isUntracked }
    }

    public var isEmpty: Bool { conflicts.isEmpty && staged.isEmpty && unstaged.isEmpty }
}

public enum GitControlPaths {
    /// A repository-relative path made relative to `folder` (the diff pane runs git there), with `..`
    /// when the folder is a subfolder of the repository and the file lies outside it.
    public static func folderRelative(_ repositoryPath: String, root: URL, folder: URL) -> String {
        let target = root.appending(path: repositoryPath).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + target[common...]
        return parts.joined(separator: "/")
    }
}

/// Validation of a new branch name, following `git check-ref-format --branch`.
public enum GitBranchName {
    public enum Issue: Equatable, Sendable {
        case empty
        case invalid
        case exists
    }

    /// Characters git never allows in a ref name.
    private static let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        .union(.controlCharacters)
        .union(.whitespacesAndNewlines)

    /// The problem with `name` (already trimmed by the caller), or nil when git accepts it and no
    /// branch in `existing` has it.
    public static func issue(_ name: String, existing: [String] = []) -> Issue? {
        if name.isEmpty { return .empty }
        if !isValid(name) { return .invalid }
        if existing.contains(name) { return .exists }
        return nil
    }

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("-"), !name.hasPrefix("/"),
              !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("//"), !name.contains("@{"),
              !name.unicodeScalars.contains(where: { forbidden.contains($0) || $0.value == 0x7F })
        else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}
