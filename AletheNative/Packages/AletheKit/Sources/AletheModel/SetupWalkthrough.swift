import Foundation

/// First-run steps on Home (upstream `SetupWalkthrough`, extended with the agents and a first terminal).
public enum SetupStep: String, CaseIterable, Codable, Sendable {
    /// At least one agent CLI is installed.
    case agents
    case project
    case terminal
    /// The user looked at the themes.
    case appearance
}

public struct SetupProgress: Equatable, Sendable {
    public var done: Set<SetupStep>

    /// Steps done by what exists, plus those marked done (`PreferencesDocument.setupDone`).
    public init(document: WorkspaceDocument, agentsFound: Bool, marked: [String]?) {
        var done = Set((marked ?? []).compactMap(SetupStep.init(rawValue:)))
        if agentsFound { done.insert(.agents) }
        if !document.projects.isEmpty { done.insert(.project) }
        if document.projects.contains(where: { $0.panes.contains { $0.content.isTerminal } }) { done.insert(.terminal) }
        self.done = done
    }

    public var count: Int { done.count }
    public var total: Int { SetupStep.allCases.count }
    public var isComplete: Bool { count == total }
}
