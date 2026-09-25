import Foundation

/// Which folder a launch or an open request asks for (upstream `cli_launch.rs`).
public enum CLILaunch {
    public static let openPathFlag = "--open-path"

    /// The target argument after argv[0]: `--open-path <dir>`, `--open-path=<dir>` or the first
    /// positional. Unlike upstream, a single-dash flag (`-AletheDataRoot /x`, Xcode's
    /// `-NSDocumentRevisionsDebugMode YES`) takes the next argument as its value, as macOS user
    /// defaults read them; `-psn_…` (Finder's process serial number) stands alone.
    public static func pathArgument(in arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == openPathFlag {
                return index < arguments.count ? arguments[index] : nil
            }
            if argument.hasPrefix(openPathFlag + "=") {
                return String(argument.dropFirst(openPathFlag.count + 1))
            }
            if argument.hasPrefix("--") || argument.hasPrefix("-psn_") { continue }
            if argument.hasPrefix("-"), argument.count > 1 {
                index += 1
                continue
            }
            return argument
        }
        return nil
    }

    /// The folder `arguments` ask for, relative paths against `cwd` (the caller's folder).
    public static func resolveTarget(arguments: [String], cwd: URL) -> URL? {
        guard let raw = pathArgument(in: arguments) else { return nil }
        return resolve(raw, cwd: cwd)
    }

    /// `raw` as an existing folder: `~` expanded, relative to `cwd`, symlinks resolved; a file
    /// resolves to its folder; anything else (missing, empty) to nil.
    public static func resolve(_ raw: String, cwd: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(filePath: expanded)
            : cwd.appending(path: expanded)
        return directory(for: candidate)
    }

    /// An existing folder itself, or the folder of an existing file.
    public static func directory(for url: URL) -> URL? {
        let resolved = canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? resolved : resolved.deletingLastPathComponent()
    }

    /// Standardized, symlinks resolved, no trailing slash: the form folder comparisons use.
    public static func canonical(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.resolvingSymlinksInPath().path, directoryHint: .inferFromPath)
    }

    /// Whether two paths name the same folder.
    public static func samePath(_ a: String, _ b: String) -> Bool {
        let expand = { (path: String) in URL(filePath: (path as NSString).expandingTildeInPath) }
        return canonical(expand(a)).path == canonical(expand(b)).path
    }

    /// The first candidate whose folder is `folder`; `preferred` wins when it matches too.
    public static func match<ID: Equatable>(folder: String, in candidates: [(id: ID, folder: String)],
                                            preferred: ID? = nil) -> ID? {
        let matches = candidates.filter { samePath($0.folder, folder) }.map(\.id)
        if let preferred, matches.contains(preferred) { return preferred }
        return matches.first
    }
}
