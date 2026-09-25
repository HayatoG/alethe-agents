import Foundation

public struct ConflictFile: Sendable, Hashable, Codable {
    public var path: String
    public var `class`: ConflictClass

    public init(path: String, class: ConflictClass) {
        self.path = path
        self.class = `class`
    }

    public init(path: String) { self.init(path: path, class: .classify(path)) }
}

/// The outcome of a trial merge `source → target`.
public struct MergeAnalysis: Sendable, Hashable, Codable {
    public var clean: Bool
    public var source: String
    public var target: String
    public var conflicts: [ConflictFile]
    /// Distinct classes of `conflicts`, sorted by upstream variant name.
    public var classes: [ConflictClass]

    public init(clean: Bool, source: String, target: String, conflicts: [ConflictFile]) {
        self.clean = clean
        self.source = source
        self.target = target
        self.conflicts = conflicts
        self.classes = Self.distinctClasses(conflicts)
    }

    static func distinctClasses(_ conflicts: [ConflictFile]) -> [ConflictClass] {
        Array(Set(conflicts.map(\.class))).sorted { $0.variantName < $1.variantName }
    }
}

/// Stages of the Merge Center sheet, in order.
public enum MergeCenterStage: String, Sendable, Hashable, Codable, CaseIterable {
    case analyze, prepare, validate, finish

    public var next: MergeCenterStage? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index + 1 < all.count ? all[index + 1] : nil
    }

    /// The stage that follows an analysis: a clean merge skips conflict preparation.
    public static func after(_ analysis: MergeAnalysis) -> MergeCenterStage {
        analysis.clean ? .validate : .prepare
    }
}
