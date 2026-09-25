import Foundation

/// The `alethe` terminal command (upstream `cli_shim.rs`): a POSIX script in `~/.local/bin` that
/// opens a folder in the app. It records the app bundle it opens and its own format version, so a
/// moved or reinstalled app (or an older script) shows up as stale.
public enum CLIShim {
    public static let fileName = "alethe"
    /// Bumped whenever the script text changes, so shims written by older builds read as stale.
    public static let version = 1
    static let targetMarker = "ALETHE_TARGET_APP:"
    static let versionMarker = "ALETHE_SHIM_VERSION:"
    static let pathProbePrefix = "__ALETHE_PATH__="

    /// What is at the shim's path, compared with the running app.
    public enum State: Equatable, Sendable {
        /// No file.
        case missing
        /// Written by this app, in the current format.
        case current
        /// Written by Alethe, but for another app bundle or in an older format.
        case stale
        /// A file Alethe did not write (no marker): replacing it asks first.
        case foreign
    }

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// A POSIX shell single-quoted word.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The script for the app bundle at `appPath`; nil for a path a comment line cannot hold.
    public static func script(appPath: String) -> String? {
        guard !appPath.isEmpty, !appPath.contains(where: \.isNewline) else { return nil }
        let app = quote(appPath)
        return """
        #!/bin/sh
        # alethe: opens a folder in Alethe from the terminal.
        #
        # Written by Alethe (Settings > General > Command Line Tool). Do not edit it by hand:
        # reinstall it from there, especially after moving or reinstalling the app.
        #
        #   alethe             opens the current folder
        #   alethe .           same
        #   alethe ~/project   opens the given folder (a file opens its folder)
        #
        # \(targetMarker) \(appPath)
        # \(versionMarker) \(version)

        set -e

        case "${1:-}" in
          -h|--help)
            echo "usage: alethe [folder]"
            exit 0
            ;;
        esac

        target=${1:-.}

        if [ -f "$target" ]; then
          target=$(dirname -- "$target")
        fi

        if [ ! -d "$target" ]; then
          echo "alethe: folder not found: $target" >&2
          exit 1
        fi

        # Absolute path: the app compares it with the saved project folders.
        target=$(cd -- "$target" && pwd -P)

        if [ ! -d \(app) ]; then
          echo "alethe: Alethe is no longer at "\(app)"; reinstall the command from its Settings" >&2
          exit 1
        fi

        exec /usr/bin/open -a \(app) "$target"

        """
    }

    /// The value after `marker` on its comment line.
    static func value(of marker: String, in contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The app bundle a shim opens, or nil when it was not written by Alethe.
    public static func targetApp(in contents: String) -> String? {
        value(of: targetMarker, in: contents)
    }

    public static func state(of contents: String?, appPath: String) -> State {
        guard let contents else { return .missing }
        guard let target = targetApp(in: contents) else { return .foreign }
        let current = target == appPath && value(of: versionMarker, in: contents) == String(version)
        return current ? .current : .stale
    }

    // MARK: - Files

    public static func location(in directory: URL) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The shim's text, or nil when there is no readable file.
    public static func read(in directory: URL) -> String? {
        try? String(contentsOf: location(in: directory), encoding: .utf8)
    }

    /// Writes the shim (atomically, mode 755), creating the folder; returns its location.
    @discardableResult
    public static func install(appPath: String, in directory: URL) throws -> URL {
        guard let text = script(appPath: appPath) else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = location(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Removes the shim when Alethe wrote it; a foreign file is left alone. Missing is not an error.
    public static func uninstall(in directory: URL) throws {
        let file = location(in: directory)
        guard let contents = read(in: directory) else {
            if FileManager.default.fileExists(atPath: file.path) { throw CocoaError(.fileReadNoPermission) }
            return
        }
        guard targetApp(in: contents) != nil else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: file)
    }

    // MARK: - PATH

    /// Whether `directory` is one of the entries of a `PATH` value (`~` expanded, trailing slashes ignored).
    public static func pathContains(_ directory: URL, pathVariable: String) -> Bool {
        let target = directory.standardizedFileURL.path
        return pathVariable.split(separator: ":").contains { entry in
            let expanded = (String(entry) as NSString).expandingTildeInPath
            return URL(filePath: expanded).standardizedFileURL.path == target
        }
    }

    /// Run through the user's login shell to learn its `PATH`: a GUI app inherits launchd's short
    /// one. The marker line survives whatever the profile prints first.
    public static let pathProbeCommand = #"printf '\n__ALETHE_PATH__=%s\n' "$PATH""#

    public static func parsePathProbe(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(pathProbePrefix) }
            .map { String($0.dropFirst(pathProbePrefix.count)) }
    }

    /// The profile line that puts `~/.local/bin` on the PATH (shown, never written, by the app).
    public static let pathExportLine = #"export PATH="$HOME/.local/bin:$PATH""#
}
