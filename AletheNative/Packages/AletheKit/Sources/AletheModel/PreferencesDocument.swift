import AletheFoundation
import Foundation

/// User preferences, persisted as `preferences.json` in the profile folder.
public struct PreferencesDocument: VersionedDocument, Hashable {
    public static let currentVersion = 1
    public static let migrations: [Int: @Sendable (inout JSONObject) throws -> Void] = [:]
    public static let initial = PreferencesDocument()

    public static let defaultThemeID = "elite-indigo"
    public static let uiScaleRange: ClosedRange<Double> = 0.8...1.5
    public static let uiScaleStep = 0.1

    public var schemaVersion: Int
    public var themeID: String
    /// UI zoom (⌘+ / ⌘− / ⌘0); scales fonts and metrics.
    public var uiScale: Double
    /// New agent tabs start with the agent's unrestricted flag.
    public var alwaysStartUnrestricted: Bool
    /// Agent kinds offered when creating a terminal; nil means all known agents.
    public var enabledAgents: [String]?
    /// Last choice in the new-terminal sheet.
    public var lastAgent: String?
    /// Per-agent CLI path overrides, keyed by agent kind; unset agents are resolved automatically.
    public var cliPaths: [String: String]?
    /// When idle terminals may be hibernated (P2-24); nil is the default policy.
    public var resourcePolicy: ResourcePolicy?
    /// Open with an empty workspace instead of the last one (P2-26; upstream `alwaysStartOnHome`).
    public var startClean: Bool?
    /// Ask before quitting while terminals run (P2-26); nil means yes.
    public var confirmQuit: Bool?
    /// `normal` or `clean` (upstream `visualStyle`, P2-27); nil is normal.
    public var visualStyle: String?
    /// Reduced motion even when macOS Reduce Motion is off (upstream `motionPreference`, P2-27).
    public var reducedMotion: Bool?
    /// The last New Terminal choice, for New Terminal Like Last ⌥⌘T (upstream
    /// `lastTerminalCreation`, P3-4).
    public var lastTerminalCreation: TerminalCreation?
    /// Notify when an agent finishes or needs an answer out of view (P3-11); nil means yes.
    public var notifyAgents: Bool?
    /// Providers with a usage pill in the toolbar (`claude`, `codex`, `antigravity`; P3-13).
    public var usagePills: [String]?
    /// Notify when a usage limit resets (upstream `notifyOnLimitReset`); nil means yes.
    public var notifyLimitReset: Bool?
    /// Open on Home instead of the workspace (upstream `alwaysStartOnHome`; P3-15).
    public var startOnHome: Bool?
    /// Setup steps marked done by hand (`SetupStep` raw values; P3-16).
    public var setupDone: [String]?
    /// The setup walkthrough was hidden (upstream `setupWalkthroughHidden`).
    public var setupHidden: Bool?
    /// Optional modules turned on or off, keyed by `Feature` raw value (upstream `enabledFeatures`);
    /// read through `features`.
    public var enabledFeatures: [String: Bool]?

    public init(schemaVersion: Int = currentVersion, themeID: String = defaultThemeID, uiScale: Double = 1,
                alwaysStartUnrestricted: Bool = false, enabledAgents: [String]? = nil, lastAgent: String? = nil,
                cliPaths: [String: String]? = nil) {
        self.schemaVersion = schemaVersion
        self.themeID = themeID
        self.uiScale = uiScale
        self.alwaysStartUnrestricted = alwaysStartUnrestricted
        self.enabledAgents = enabledAgents
        self.lastAgent = lastAgent
        self.cliPaths = cliPaths
    }

    public var resources: ResourcePolicy { resourcePolicy ?? ResourcePolicy() }

    public mutating func zoom(by steps: Int) {
        let next = (uiScale + Double(steps) * Self.uiScaleStep) * 10
        uiScale = min(max(next.rounded() / 10, Self.uiScaleRange.lowerBound), Self.uiScaleRange.upperBound)
    }
}

/// A terminal as New Terminal created it, repeated by New Terminal Like Last.
public struct TerminalCreation: Codable, Hashable, Sendable {
    public var agent: String
    /// A folder other than the project's; nil runs in the project folder.
    public var folder: String?
    public var unrestricted: Bool
    public var extraArguments: [String]

    public init(agent: String, folder: String? = nil, unrestricted: Bool = false, extraArguments: [String] = []) {
        self.agent = agent
        self.folder = folder
        self.unrestricted = unrestricted
        self.extraArguments = extraArguments
    }

    /// A new tab like the one this records.
    public func tab() -> PaneTab {
        PaneTab(agent: agent, workingDirectory: folder, unrestricted: unrestricted, extraArguments: extraArguments)
    }
}
