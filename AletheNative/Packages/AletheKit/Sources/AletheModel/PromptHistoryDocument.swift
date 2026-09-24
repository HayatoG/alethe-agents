import AletheFoundation
import Foundation

/// `prompt-history.json` in the profile folder: each terminal tab's prompt history (upstream keeps
/// it in scoped browser storage, `prompt-history:<pty id>`).
public struct PromptHistoryDocument: VersionedDocument, Hashable {
    public static let currentVersion = 1
    public static let migrations: [Int: @Sendable (inout JSONObject) throws -> Void] = [:]
    public static let initial = PromptHistoryDocument()

    public var schemaVersion: Int
    /// Tab id → submitted prompts, oldest first.
    public var histories: [String: [String]]

    public init(schemaVersion: Int = currentVersion, histories: [String: [String]] = [:]) {
        self.schemaVersion = schemaVersion
        self.histories = histories
    }

    /// Drops the histories of tabs that no longer exist.
    public mutating func prune(keeping tabs: Set<TabID>) {
        let kept = Set(tabs.map(\.rawValue))
        histories = histories.filter { kept.contains($0.key) }
    }
}

public typealias PromptHistoryModel = DocumentModel<PromptHistoryDocument>
