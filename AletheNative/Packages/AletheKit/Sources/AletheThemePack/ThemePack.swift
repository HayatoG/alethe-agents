import AletheDesign
import AlethePluginKit
import Foundation

public enum ThemePackError: Error, Equatable {
    case missingResource(String)
    case invalidResource(String)
}

/// Upstream's theme-pack themes (Ember, Golden Premium, Dark Lemon, Orca), converted to the native
/// theme format by `Scripts/oneshot/convert-themes.py --theme-pack`.
public enum ThemePack {
    /// Picker order, matching upstream's `THEME_PACK_THEMES`.
    public static let themeIDs = ["dark-lemon", "orca", "ember", "golden-premium"]

    /// One contribution per bundled theme, named by the JSON's `name`.
    public static func contributions() throws -> [ThemeContribution] {
        try contributions(bundle: .module)
    }

    static func contributions(bundle: Bundle) throws -> [ThemeContribution] {
        try themeIDs.map { id in
            guard let url = bundle.url(forResource: id, withExtension: "json", subdirectory: "Themes") else {
                throw ThemePackError.missingResource(id)
            }
            let data = try Data(contentsOf: url)
            guard let header = try? JSONDecoder().decode(Header.self, from: data), header.id == id else {
                throw ThemePackError.invalidResource(id)
            }
            return ThemeContribution(id: id, name: header.name, data: data)
        }
    }

    private struct Header: Decodable {
        let id: String
        let name: String
    }
}

/// Built-in data plugin: contributes the theme pack on the theme contribution point.
public final class ThemePackPlugin: AlethePlugin {
    public static let manifest = PluginManifest(id: "alethe.theme-pack", version: "1.0.0", name: "Theme Pack")

    public init() {}

    public func activate(context: PluginContext) throws {
        for theme in try ThemePack.contributions() {
            try context.addTheme(theme)
        }
    }
}

extension ThemeCatalog {
    /// This catalog plus every contribution that decodes to a valid theme with a new id, for the
    /// picker. Undecodable contributions are dropped rather than failing the whole list.
    public func merging(contributions: [ThemeContribution]) -> ThemeCatalog {
        let decoder = JSONDecoder()
        let themes = contributions.compactMap { contribution -> Theme? in
            guard let theme = try? decoder.decode(Theme.self, from: contribution.data),
                  theme.id == contribution.id else { return nil }
            return theme
        }
        return merging(themes)
    }
}
