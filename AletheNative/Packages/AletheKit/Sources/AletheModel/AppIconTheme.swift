import Foundation

/// The Dock icon artwork (upstream `AppIconTheme`, `src/assets/theme-icons/`), independent of the
/// interface theme. Applied at run time; the bundle's own icon is never changed.
public enum AppIconTheme: String, CaseIterable, Codable, Hashable, Sendable {
    case eliteOriginal = "elite-original"
    case elitePureBlack = "elite-pure-black"
    case eliteIndigo = "elite-indigo"
    case eliteBlush = "elite-blush"

    /// Upstream `normalizeAppIconTheme` fallback.
    public static let `default` = AppIconTheme.eliteIndigo

    /// Unknown or missing values fall back to the default, as upstream normalizes them.
    public init(normalizing value: String?) {
        self = value.flatMap(AppIconTheme.init(rawValue:)) ?? .default
    }

    /// The image set in the app's asset catalog.
    public var assetName: String { "AppIcon-\(rawValue)" }
}

extension PreferencesDocument {
    /// `appIconTheme` resolved; setting the default stores nil.
    public var iconTheme: AppIconTheme {
        get { AppIconTheme(normalizing: appIconTheme) }
        set { appIconTheme = newValue == .default ? nil : newValue.rawValue }
    }
}
