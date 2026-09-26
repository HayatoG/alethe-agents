import Foundation

/// Upstream `remote/appearance.rs` rules: the phone only ever receives a known theme, icon,
/// language and motion value, so a stray preference can never reach the client's CSS or DOM.
public extension RemoteAppearance {
    static let defaultTheme = "elite-indigo"

    static let knownThemes: Set<String> = [
        "elite-original", "elite-pure-black", "elite-indigo", "elite-blush", "dark", "light",
        "dracula", "nord", "gruvbox", "solarized", "tokyo-night", "vscode", "min-dark", "min-light",
        "dark-lemon", "orca", "ember", "golden-premium",
    ]

    static let lightThemes: Set<String> = ["elite-original", "elite-blush", "light", "min-light"]

    static let knownAppIcons: Set<String> = ["elite-original", "elite-pure-black", "elite-indigo", "elite-blush"]

    /// The appearance for persisted preference values (upstream `appearance_from_document`);
    /// anything unknown or missing falls back to the branded dark default.
    static func resolved(
        uiTheme: String?,
        appIconTheme: String?,
        language: String?,
        motionPreference: String?
    ) -> RemoteAppearance {
        let theme = uiTheme.flatMap { knownThemes.contains($0) ? $0 : nil } ?? defaultTheme
        return RemoteAppearance(
            uiTheme: theme,
            appIconTheme: appIconTheme.flatMap { knownAppIcons.contains($0) ? $0 : nil } ?? defaultTheme,
            language: language == "pt-BR" ? "pt-BR" : "en",
            motionPreference: motionPreference == "reduced" ? "reduced" : "animated",
            colorScheme: lightThemes.contains(theme) ? "light" : "dark"
        )
    }

    /// The defaults upstream serves when no preferences exist.
    static let fallback = resolved(uiTheme: nil, appIconTheme: nil, language: nil, motionPreference: nil)

    /// This appearance with the rules re-applied (the color scheme is always derived).
    var normalized: RemoteAppearance {
        Self.resolved(uiTheme: uiTheme, appIconTheme: appIconTheme, language: language, motionPreference: motionPreference)
    }
}
