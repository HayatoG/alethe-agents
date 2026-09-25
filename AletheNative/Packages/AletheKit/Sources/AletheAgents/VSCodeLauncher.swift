import Foundation

/// How to open a folder in VS Code (P5-7; upstream `open_in_vscode`/`find_vscode_launcher`): the
/// `code` CLI through the launcher resolver, else the app by bundle id (VS Code, then Insiders,
/// then VSCodium), else missing.
public enum VSCodeLauncher {
    public static let command = "code"
    public static let bundleIdentifiers = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]

    public enum Resolution: Equatable, Sendable {
        case cli(String)
        case app(URL)
        case missing
    }

    /// `appURL` maps a bundle id to the installed app (`NSWorkspace.urlForApplication(withBundleIdentifier:)`).
    public static func resolve(resolver: (String) -> String?, appURL: (String) -> URL?) -> Resolution {
        if let cli = resolver(command) { return .cli(cli) }
        for identifier in bundleIdentifiers {
            if let url = appURL(identifier) { return .app(url) }
        }
        return .missing
    }

    /// Arguments for the CLI: the folder only, refused when it could read as an option.
    public static func arguments(opening path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        return [path]
    }
}
