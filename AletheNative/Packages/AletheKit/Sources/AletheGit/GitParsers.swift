import Foundation

// MARK: - Models

/// One side (index or worktree) of a status entry.
public enum GitChange: String, Hashable, Sendable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C"
    case typeChanged = "T", unmerged = "U"

    init?(code: Character) {
        guard code != "." && code != " " && code != "?" && code != "!" else { return nil }
        self.init(rawValue: String(code))
    }
}

public struct GitSubmoduleState: Hashable, Sendable {
    public var commitChanged: Bool
    public var hasTrackedChanges: Bool
    public var hasUntracked: Bool
}

public struct GitStatusEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case ordinary, renamed, unmerged, untracked, ignored }
    public var kind: Kind
    public var path: String
    /// The source path of a rename or copy.
    public var originalPath: String?
    public var index: GitChange?
    public var worktree: GitChange?
    public var submodule: GitSubmoduleState?

    public var isStaged: Bool { kind != .unmerged && index != nil }
    public var isUnstaged: Bool { kind != .unmerged && worktree != nil }
    public var isConflict: Bool { kind == .unmerged }
    public var isUntracked: Bool { kind == .untracked }
}

public struct GitBranchStatus: Hashable, Sendable {
    /// The branch name, `nil` when detached.
    public var head: String?
    /// The commit, `nil` before the first commit.
    public var oid: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0

    public var isDetached: Bool { head == nil }
}

public struct GitStatus: Hashable, Sendable {
    public var branch: GitBranchStatus
    public var entries: [GitStatusEntry]

    public var staged: [GitStatusEntry] { entries.filter(\.isStaged) }
    public var unstaged: [GitStatusEntry] { entries.filter(\.isUnstaged) }
    public var conflicts: [GitStatusEntry] { entries.filter(\.isConflict) }
    public var untracked: [GitStatusEntry] { entries.filter(\.isUntracked) }
    public var isClean: Bool { entries.allSatisfy { $0.kind == .ignored } }
}

/// A file changed by a commit or between two trees (`--name-status`).
public struct GitFileChange: Hashable, Sendable {
    public var path: String
    public var originalPath: String?
    public var change: GitChange
}

/// Lines added and removed in one file (`--numstat`); `nil` counts mean a binary file.
public struct GitDiffStat: Hashable, Sendable {
    public var path: String
    public var originalPath: String?
    public var added: Int?
    public var deleted: Int?

    public var isBinary: Bool { added == nil }
}

public struct GitRef: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case head, branch, remoteBranch, tag, other }
    public var kind: Kind
    public var name: String
    /// True for the branch HEAD points at (`HEAD -> refs/heads/main`).
    public var isCurrent = false
}

public struct GitCommit: Hashable, Sendable, Identifiable {
    public var hash: String
    public var parents: [String]
    public var refs: [GitRef]
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var subject: String

    public var id: String { hash }
    public var isMerge: Bool { parents.count > 1 }
}

public struct GitBranch: Hashable, Sendable, Identifiable {
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var oid: String
    public var upstream: String?

    public var id: String { (isRemote ? "remote/" : "local/") + name }
}

public struct GitIncomingOutgoing: Hashable, Sendable {
    public var upstream: String
    /// Commits on the upstream not yet in HEAD.
    public var incoming: [GitCommit]
    /// Commits in HEAD not yet on the upstream.
    public var outgoing: [GitCommit]
}

// MARK: - Parsers (pure)

public enum GitParsers {
    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// `git log` format consumed by `parseLog`.
    public static let logFormat = "--format=%H%x1f%P%x1f%D%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"
    /// `git for-each-ref` format consumed by `parseBranches`.
    public static let branchFormat = "--format=%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(HEAD)"

    private static func nulFields(_ text: String) -> [Substring] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.last == "" { fields.removeLast() }
        return fields
    }

    /// Parses `git status --porcelain=v2 -z --branch`.
    public static func parseStatus(_ text: String) -> GitStatus {
        var branch = GitBranchStatus()
        var entries: [GitStatusEntry] = []
        let fields = nulFields(text)
        var i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            guard let tag = record.first else { continue }
            switch tag {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let value = String(parts[2])
                switch parts[1] {
                case "branch.oid": branch.oid = value == "(initial)" ? nil : value
                case "branch.head": branch.head = value == "(detached)" ? nil : value
                case "branch.upstream": branch.upstream = value
                case "branch.ab":
                    for token in value.split(separator: " ") {
                        if token.hasPrefix("+") { branch.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { branch.behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1", "2", "u":
                // Field counts before the path: 1 → 8, 2 → 9, u → 10.
                let leading = tag == "1" ? 8 : tag == "2" ? 9 : 10
                let parts = record.split(separator: " ", maxSplits: leading, omittingEmptySubsequences: false)
                guard parts.count == leading + 1 else { continue }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                var entry = GitStatusEntry(
                    kind: tag == "1" ? .ordinary : tag == "2" ? .renamed : .unmerged,
                    path: String(parts[leading]),
                    index: GitChange(code: xy[0]),
                    worktree: GitChange(code: xy[1]),
                    submodule: parseSubmodule(parts[2])
                )
                if tag == "2", i < fields.count {
                    entry.originalPath = String(fields[i])
                    i += 1
                }
                entries.append(entry)
            case "?", "!":
                let path = String(record.dropFirst(2))
                entries.append(GitStatusEntry(kind: tag == "?" ? .untracked : .ignored, path: path))
            default:
                continue
            }
        }
        return GitStatus(branch: branch, entries: entries)
    }

    static func parseSubmodule(_ field: Substring) -> GitSubmoduleState? {
        let chars = Array(field)
        guard chars.count == 4, chars[0] == "S" else { return nil }
        return GitSubmoduleState(commitChanged: chars[1] == "C", hasTrackedChanges: chars[2] == "M", hasUntracked: chars[3] == "U")
    }

    /// Parses `--name-status -z` (git diff / diff-tree): `M\0path\0`, `R100\0old\0new\0`.
    public static func parseNameStatus(_ text: String) -> [GitFileChange] {
        let fields = nulFields(text)
        var changes: [GitFileChange] = []
        var i = 0
        while i < fields.count {
            let code = fields[i]
            i += 1
            guard let letter = code.first, let change = GitChange(code: letter) else { continue }
            if change == .renamed || change == .copied {
                guard i + 1 < fields.count else { break }
                changes.append(GitFileChange(path: String(fields[i + 1]), originalPath: String(fields[i]), change: change))
                i += 2
            } else {
                guard i < fields.count else { break }
                changes.append(GitFileChange(path: String(fields[i]), originalPath: nil, change: change))
                i += 1
            }
        }
        return changes
    }

    /// Parses `--numstat -z`: `a\td\tpath\0`, or for a rename `a\td\t\0old\0new\0`; `-` counts are binary.
    public static func parseNumstat(_ text: String) -> [GitDiffStat] {
        let fields = nulFields(text)
        var stats: [GitDiffStat] = []
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard parts.count == 3 else { continue }
            var stat = GitDiffStat(path: String(parts[2]), added: Int(parts[0]), deleted: Int(parts[1]))
            if parts[2].isEmpty {
                guard i + 1 < fields.count else { break }
                stat.originalPath = String(fields[i])
                stat.path = String(fields[i + 1])
                i += 2
            }
            stats.append(stat)
        }
        return stats
    }

    /// Parses `git log` output produced with `logFormat` (refs from `--decorate=full`).
    public static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: recordSeparator).compactMap { raw in
            let record = raw.trimmingCharacters(in: .newlines)
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }
            return GitCommit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                refs: parseRefs(String(fields[2])),
                authorName: String(fields[3]),
                authorEmail: String(fields[4]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[5]) ?? 0),
                subject: fields[6...].joined(separator: String(fieldSeparator))
            )
        }
    }

    /// Parses a `%D` decoration with full ref names: `HEAD -> refs/heads/main, tag: refs/tags/v1`.
    public static func parseRefs(_ decoration: String) -> [GitRef] {
        decoration.components(separatedBy: ", ").compactMap { item in
            var name = item.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if name.hasPrefix("HEAD -> ") {
                name.removeFirst("HEAD -> ".count)
                var ref = classify(name)
                ref.isCurrent = true
                return ref
            }
            if name.hasPrefix("tag: ") { name.removeFirst("tag: ".count) }
            return classify(name)
        }
    }

    private static func classify(_ full: String) -> GitRef {
        for (prefix, kind) in [("refs/heads/", GitRef.Kind.branch), ("refs/remotes/", .remoteBranch), ("refs/tags/", .tag)]
        where full.hasPrefix(prefix) {
            return GitRef(kind: kind, name: String(full.dropFirst(prefix.count)))
        }
        return GitRef(kind: full == "HEAD" ? .head : .other, name: full)
    }

    /// Parses `git for-each-ref` output produced with `branchFormat`; symbolic `*/HEAD` refs are skipped.
    public static func parseBranches(_ text: String) -> [GitBranch] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            let ref = String(fields[0])
            let upstream = fields[2].isEmpty ? nil : String(fields[2])
            if ref.hasPrefix("refs/heads/") {
                return GitBranch(name: String(ref.dropFirst(11)), isRemote: false, isCurrent: fields[3] == "*", oid: String(fields[1]), upstream: upstream)
            }
            if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                return GitBranch(name: String(ref.dropFirst(13)), isRemote: true, isCurrent: false, oid: String(fields[1]), upstream: nil)
            }
            return nil
        }
    }

    // MARK: Validation (defense against argument injection, as upstream)

    public static func validateHash(_ hash: String) throws {
        guard !hash.isEmpty, hash.count <= 64, hash.allSatisfy(\.isHexDigit) else {
            throw GitError.invalidArgument("commit hash")
        }
    }

    public static func validateBranchName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"),
              !name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw GitError.invalidArgument("branch name") }
    }

    /// Paths must be relative to the repository root and stay inside it.
    public static func validatePaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { throw GitError.invalidArgument("no paths") }
        for path in paths {
            let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            if path.trimmingCharacters(in: .whitespaces).isEmpty || path.hasPrefix("/") || path.hasPrefix("\\")
                || components.contains("..") {
                throw GitError.invalidArgument("path \(path)")
            }
        }
    }
}
