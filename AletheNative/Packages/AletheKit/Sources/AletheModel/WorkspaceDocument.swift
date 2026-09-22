import AletheFoundation
import Foundation

/// Accent color of a project or group; the UI maps each case to a theme token (`project*`).
public enum ProjectColor: String, Codable, CaseIterable, Sendable {
    case orange, pink, purple, blue, teal, green, yellow, red, gray, black
}

public struct ProjectGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: GroupID
    public var name: String
    public var color: ProjectColor?
    /// Nesting: nil for a top-level group.
    public var parentID: GroupID?
    /// Projects directly in this group, in sidebar order.
    public var projectIDs: [ProjectID]
    public var isCollapsed: Bool

    public init(id: GroupID = .make(), name: String, color: ProjectColor? = nil, parentID: GroupID? = nil,
                projectIDs: [ProjectID] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.parentID = parentID
        self.projectIDs = projectIDs
        self.isCollapsed = isCollapsed
    }
}

/// One sub-tab of a pane: an agent or shell session.
public struct PaneTab: Codable, Hashable, Sendable, Identifiable {
    public var id: TabID
    /// Agent kind raw value (`claude`, `codex`, `opencode`, `cursor`, `shell`, …).
    public var agent: String
    public var title: String?
    /// Overrides the project folder.
    public var workingDirectory: String?
    /// Agent session to resume on relaunch, once known.
    public var sessionID: String?
    public var unrestricted: Bool
    public var extraArguments: [String]
    /// Prompt sent to a new session when it starts.
    public var initialPrompt: String?
    public var createdAt: Date

    public init(id: TabID = .make(), agent: String, title: String? = nil, workingDirectory: String? = nil,
                sessionID: String? = nil, unrestricted: Bool = false, extraArguments: [String] = [],
                initialPrompt: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.title = title
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.unrestricted = unrestricted
        self.extraArguments = extraArguments
        self.initialPrompt = initialPrompt
        self.createdAt = createdAt
    }
}

/// A workspace pane (the Tauri app's "terminal"): one or more tabs, one visible.
public struct Pane: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneID
    public var tabs: [PaneTab]
    public var activeTabID: TabID?

    public init(id: PaneID = .make(), tabs: [PaneTab], activeTabID: TabID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    public var activeTab: PaneTab? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var color: ProjectColor
    /// Absolute path of the project folder; the default working directory of its panes.
    public var folder: String
    public var panes: [Pane]
    public var createdAt: Date

    public init(id: ProjectID = .make(), name: String, color: ProjectColor = .blue, folder: String,
                panes: [Pane] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.color = color
        self.folder = folder
        self.panes = panes
        self.createdAt = createdAt
    }
}

/// Relative track sizes of a pane grid; empty means equal sizes.
public struct GridWeights: Codable, Hashable, Sendable {
    public var columns: [Double]
    public var rows: [Double]

    public init(columns: [Double] = [], rows: [Double] = []) {
        self.columns = columns
        self.rows = rows
    }
}

/// What is open in the window.
public struct WorkspaceState: Codable, Hashable, Sendable {
    /// Projects shown side by side as containers, in order.
    public var openProjectIDs: [ProjectID]
    /// Relative widths of the open containers; empty means equal.
    public var containerWeights: [Double]
    /// Custom track sizes per project grid.
    public var gridWeights: [String: GridWeights]
    public var focusedPaneID: PaneID?
    public var selectedProjectID: ProjectID?

    public init(openProjectIDs: [ProjectID] = [], containerWeights: [Double] = [],
                gridWeights: [String: GridWeights] = [:], focusedPaneID: PaneID? = nil,
                selectedProjectID: ProjectID? = nil) {
        self.openProjectIDs = openProjectIDs
        self.containerWeights = containerWeights
        self.gridWeights = gridWeights
        self.focusedPaneID = focusedPaneID
        self.selectedProjectID = selectedProjectID
    }
}

/// Everything the sidebar and workspace show, persisted as `workspace.json` in the profile folder.
public struct WorkspaceDocument: VersionedDocument, Hashable {
    public static let currentVersion = 1
    public static let migrations: [Int: @Sendable (inout JSONObject) throws -> Void] = [:]
    public static let initial = WorkspaceDocument()

    public var schemaVersion: Int
    /// All groups; sibling order is array order.
    public var groups: [ProjectGroup]
    /// Projects outside any group, in sidebar order.
    public var ungroupedProjectIDs: [ProjectID]
    public var projects: [Project]
    public var workspace: WorkspaceState

    public init(schemaVersion: Int = currentVersion, groups: [ProjectGroup] = [],
                ungroupedProjectIDs: [ProjectID] = [], projects: [Project] = [],
                workspace: WorkspaceState = WorkspaceState()) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.ungroupedProjectIDs = ungroupedProjectIDs
        self.projects = projects
        self.workspace = workspace
    }
}
