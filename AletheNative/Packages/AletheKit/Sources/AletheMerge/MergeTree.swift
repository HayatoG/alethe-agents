import Foundation

/// How the sidebar merge tree groups a merge's conflicted files.
public enum MergeTreeGrouping: String, Sendable, Hashable, Codable, CaseIterable {
    case folder, `class`
}

/// One branch of the merge tree: a folder (or class) and its conflicted files.
public struct MergeTreeGroup: Sendable, Hashable, Identifiable {
    /// The folder path (`""` for the repository root) or the class's raw value.
    public var id: String
    public var title: String
    public var files: [ConflictFile]

    public init(id: String, title: String, files: [ConflictFile]) {
        self.id = id
        self.title = title
        self.files = files
    }
}

public enum MergeTree {
    /// The folder part of a repository-relative path (`""` at the root); backslashes count as `/`.
    public static func folder(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let slash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slash])
    }

    /// The file name part of a repository-relative path.
    public static func fileName(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    /// Groups `conflicts` by folder (root first, then alphabetical) or by class (upstream variant
    /// order); files inside a group are sorted by path and duplicates dropped.
    public static func groups(_ conflicts: [ConflictFile], by grouping: MergeTreeGrouping) -> [MergeTreeGroup] {
        var seen: Set<String> = []
        let unique = conflicts.filter { seen.insert($0.path).inserted }
        switch grouping {
        case .folder:
            let byFolder = Dictionary(grouping: unique) { folder(of: $0.path) }
            return byFolder.keys.sorted().map { key in
                MergeTreeGroup(id: key, title: key.isEmpty ? "." : key,
                               files: byFolder[key]!.sorted { $0.path < $1.path })
            }
        case .class:
            let byClass = Dictionary(grouping: unique, by: \.class)
            return byClass.keys.sorted { $0.variantName < $1.variantName }.map { key in
                MergeTreeGroup(id: key.rawValue, title: key.variantName,
                               files: byClass[key]!.sorted { $0.path < $1.path })
            }
        }
    }
}

/// An in-progress merge environment found on disk, for the sidebar panel and resuming the Merge
/// Center.
public struct MergeSessionSummary: Sendable, Hashable, Identifiable {
    public var meta: MergeMeta
    public var stage: MergeCenterStage
    public var id: String { meta.id }
    public var conflicts: [ConflictFile] { meta.conflictPaths.map { ConflictFile(path: $0) } }

    public init(meta: MergeMeta) {
        self.meta = meta
        stage = MergeResumePoint.stage(recorded: meta.stage, conflictPaths: meta.conflictPaths)
    }
}

/// Where a reopened Merge Center lands for an existing environment.
public enum MergeResumePoint {
    /// The recorded stage (never Analyze: the environment already exists). Without a record:
    /// Prepare when the merge had conflicts, else Validate. Files still unmerged (`unresolved`, when
    /// known) always send it back to Prepare.
    public static func stage(recorded: MergeCenterStage?, conflictPaths: [String], unresolved: [String]? = nil) -> MergeCenterStage {
        let base: MergeCenterStage
        if let recorded, recorded != .analyze {
            base = recorded
        } else {
            base = conflictPaths.isEmpty ? .validate : .prepare
        }
        if let unresolved, !unresolved.isEmpty { return .prepare }
        return base
    }
}
