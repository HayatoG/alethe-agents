import AletheDesign
import SwiftUI

/// Picker names of the built-in themes (upstream `theme.<id>.label` / `.desc`). Keys are literal so
/// the string gate can see them; an unknown id (a plugin theme, later) shows its id.
extension Theme {
    var localizedName: Text {
        switch id {
        case "elite-original": Text("theme.eliteOriginal")
        case "elite-pure-black": Text("theme.elitePureBlack")
        case "elite-indigo": Text("theme.eliteIndigo")
        case "elite-blush": Text("theme.eliteBlush")
        case "dark": Text("theme.dark")
        case "light": Text("theme.light")
        case "dracula": Text("theme.dracula")
        case "nord": Text("theme.nord")
        case "gruvbox": Text("theme.gruvbox")
        case "solarized": Text("theme.solarized")
        case "tokyo-night": Text("theme.tokyoNight")
        case "vscode": Text("theme.vscode")
        case "min-dark": Text("theme.minDark")
        case "min-light": Text("theme.minLight")
        case "catppuccin-frappe": Text("theme.catppuccinFrappe")
        case "gruvbox-material": Text("theme.gruvboxMaterial")
        case "dark-lemon": Text("theme.darkLemon")
        case "orca": Text("theme.orca")
        case "ember": Text("theme.ember")
        case "golden-premium": Text("theme.goldenPremium")
        default: Text(verbatim: id)
        }
    }

    var localizedSummary: Text? {
        switch id {
        case "elite-original": Text("theme.eliteOriginal.summary")
        case "elite-pure-black": Text("theme.elitePureBlack.summary")
        case "elite-indigo": Text("theme.eliteIndigo.summary")
        case "elite-blush": Text("theme.eliteBlush.summary")
        case "dark": Text("theme.dark.summary")
        case "light": Text("theme.light.summary")
        case "dracula": Text("theme.dracula.summary")
        case "nord": Text("theme.nord.summary")
        case "gruvbox": Text("theme.gruvbox.summary")
        case "solarized": Text("theme.solarized.summary")
        case "tokyo-night": Text("theme.tokyoNight.summary")
        case "vscode": Text("theme.vscode.summary")
        case "min-dark": Text("theme.minDark.summary")
        case "min-light": Text("theme.minLight.summary")
        case "catppuccin-frappe": Text("theme.catppuccinFrappe.summary")
        case "gruvbox-material": Text("theme.gruvboxMaterial.summary")
        default: nil
        }
    }
}
