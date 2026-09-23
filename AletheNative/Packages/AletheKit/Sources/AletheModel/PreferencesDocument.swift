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

    public mutating func zoom(by steps: Int) {
        let next = (uiScale + Double(steps) * Self.uiScaleStep) * 10
        uiScale = min(max(next.rounded() / 10, Self.uiScaleRange.lowerBound), Self.uiScaleRange.upperBound)
    }
}
