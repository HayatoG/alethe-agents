import Foundation

public enum ThemeCatalogError: Error, Equatable {
    case missingResource(String)
    case invalidTheme(id: String, problems: [String])
}

/// Built-in themes bundled with the app, in picker order.
public struct ThemeCatalog: Sendable {
    /// Picker order, matching the Tauri app's `BUILTIN_THEME_OPTIONS`.
    public static let builtinOrder = [
        "elite-original", "elite-pure-black", "elite-indigo", "elite-blush",
        "dark", "light", "dracula", "nord", "gruvbox", "solarized", "tokyo-night", "vscode",
        "min-dark", "min-light", "catppuccin-frappe", "gruvbox-material",
    ]
    public static let defaultThemeID = "elite-indigo"
    /// Theme used when a stored id is unknown (e.g. its plugin is disabled).
    public static let fallbackThemeID = "dark"

    public let themes: [Theme]

    public static let builtin: ThemeCatalog = {
        do {
            return try ThemeCatalog(bundle: .module)
        } catch {
            preconditionFailure("Bundled themes are invalid: \(error)")
        }
    }()

    public init(bundle: Bundle) throws {
        let decoder = JSONDecoder()
        themes = try Self.builtinOrder.map { id in
            guard let url = bundle.url(forResource: id, withExtension: "json", subdirectory: "Themes") else {
                throw ThemeCatalogError.missingResource(id)
            }
            let theme = try decoder.decode(Theme.self, from: Data(contentsOf: url))
            let problems = theme.validationErrors
            guard problems.isEmpty, theme.id == id else {
                throw ThemeCatalogError.invalidTheme(id: id, problems: problems)
            }
            return theme
        }
    }

    public func theme(id: String) -> Theme? {
        themes.first { $0.id == id }
    }

    /// The theme to apply for a stored preference; unknown ids fall back without touching the preference.
    public func resolved(id: String) -> Theme {
        theme(id: id) ?? theme(id: Self.fallbackThemeID) ?? themes[0]
    }

    public var defaultTheme: Theme { resolved(id: Self.defaultThemeID) }
}
