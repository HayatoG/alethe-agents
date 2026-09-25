import Foundation

/// Contribution points (ADR-9). Views are referenced by `viewID`; the app maps each id to the view
/// the plugin's module provides, so this package stays free of UI code.

public enum SidebarSide: String, Hashable, Sendable, Codable {
    case left
    case right
}

public struct SidebarTabContribution: Hashable, Sendable {
    public var id: String
    public var title: String
    /// SF Symbol name.
    public var symbol: String
    public var side: SidebarSide
    public var viewID: String

    public init(id: String, title: String, symbol: String, side: SidebarSide = .left, viewID: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.side = side
        self.viewID = viewID
    }
}

public struct CommandContribution: Sendable, Identifiable {
    public struct Placement: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let menu = Placement(rawValue: 1 << 0)
        /// Listed in Find/Jump.
        public static let findJump = Placement(rawValue: 1 << 1)
        public static let all: Placement = [.menu, .findJump]
    }

    public var id: String
    public var title: String
    public var placement: Placement
    /// Key equivalent with ⌘ (ADR-10), e.g. `"k"`; nil for none.
    public var keyEquivalent: String?
    public var perform: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        placement: Placement = .all,
        keyEquivalent: String? = nil,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.placement = placement
        self.keyEquivalent = keyEquivalent
        self.perform = perform
    }
}

public struct ThemeContribution: Hashable, Sendable {
    public var id: String
    public var name: String
    /// Theme JSON in the app's theme format (decoded by AletheDesign).
    public var data: Data

    public init(id: String, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }
}

public struct PaneKindContribution: Hashable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var viewID: String

    public init(id: String, title: String, symbol: String, viewID: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.viewID = viewID
    }
}

public struct SheetContribution: Hashable, Sendable {
    public var id: String
    public var title: String
    public var viewID: String

    public init(id: String, title: String, viewID: String) {
        self.id = id
        self.title = title
        self.viewID = viewID
    }
}

public struct SettingsPageContribution: Hashable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var viewID: String

    public init(id: String, title: String, symbol: String, viewID: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.viewID = viewID
    }
}

public struct AgentProviderContribution: Hashable, Sendable {
    public var id: String
    public var name: String
    /// Executable launched in the terminal (resolved on the user's PATH).
    public var command: String
    public var arguments: [String]
    /// Arguments that resume a session; `{session}` is replaced with the session id.
    public var resumeArguments: [String]?

    public init(id: String, name: String, command: String, arguments: [String] = [], resumeArguments: [String]? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.resumeArguments = resumeArguments
    }
}

/// Everything one plugin (or, aggregated, every active plugin) contributes.
public struct PluginContributions: Sendable {
    public var sidebarTabs: [SidebarTabContribution] = []
    public var commands: [CommandContribution] = []
    public var themes: [ThemeContribution] = []
    public var paneKinds: [PaneKindContribution] = []
    public var sheets: [SheetContribution] = []
    public var settingsPages: [SettingsPageContribution] = []
    public var agentProviders: [AgentProviderContribution] = []

    public init() {}

    public var isEmpty: Bool {
        sidebarTabs.isEmpty && commands.isEmpty && themes.isEmpty && paneKinds.isEmpty
            && sheets.isEmpty && settingsPages.isEmpty && agentProviders.isEmpty
    }

    mutating func append(_ other: PluginContributions) {
        sidebarTabs += other.sidebarTabs
        commands += other.commands
        themes += other.themes
        paneKinds += other.paneKinds
        sheets += other.sheets
        settingsPages += other.settingsPages
        agentProviders += other.agentProviders
    }
}
