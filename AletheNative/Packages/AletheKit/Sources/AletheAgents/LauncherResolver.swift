import Foundation
import Synchronization

/// Finds an agent's CLI on disk. Port of upstream `cli_resolver.rs` for macOS: an app started from
/// Finder inherits Launch Services' minimal PATH (no `.zshrc`/`.zprofile`), so besides PATH it walks
/// the default install roots of Homebrew and the Node/Rust version managers.
public struct LauncherResolver: Sendable {
    public var environment: [String: String]
    public var homeDirectory: String
    private let isExecutable: @Sendable (String) -> Bool
    private let listDirectory: @Sendable (String) -> [String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        },
        listDirectory: @escaping @Sendable (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.listDirectory = listDirectory
    }

    /// The executable for `command`: a valid `override` wins, then the first hit in
    /// `searchDirectories()`.
    public func resolve(_ command: String, override: String? = nil) -> String? {
        if let override = override.map(expandingTilde), !override.isEmpty, isExecutable(override) {
            return override
        }
        guard !command.isEmpty, !command.contains("/") else { return nil }
        return searchDirectories().lazy.map { ($0 as NSString).appendingPathComponent(command) }.first(where: isExecutable)
    }

    /// PATH first, then per-user install roots, then Homebrew; duplicates and empty entries dropped.
    public func searchDirectories() -> [String] {
        let home = homeDirectory
        func env(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : expandingTilde($0) } }
        let xdgData = env("XDG_DATA_HOME") ?? "\(home)/.local/share"

        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "\(home)/.local/bin",
            // Claude Code's `claude migrate-installer` location.
            "\(home)/.claude/local",
            "\(home)/.opencode/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
        ]
        if let prefix = env("NPM_CONFIG_PREFIX") { directories.append("\(prefix)/bin") }
        directories.append("\(env("VOLTA_HOME") ?? "\(home)/.volta")/bin")
        directories.append(env("PNPM_HOME") ?? "\(home)/Library/pnpm")
        directories.append("\(env("MISE_DATA_DIR") ?? "\(xdgData)/mise")/shims")
        directories.append("\(env("ASDF_DATA_DIR") ?? "\(home)/.asdf")/shims")
        directories += nvmDirectories(root: env("NVM_DIR") ?? "\(home)/.nvm")
        for root in [env("FNM_DIR"), "\(xdgData)/fnm", "\(home)/Library/Application Support/fnm"].compactMap({ $0 }) {
            directories.append("\(root)/aliases/default/bin")
            directories += versionDirectories(in: "\(root)/node-versions", suffix: "installation/bin")
        }
        directories += Self.homebrewDirectories
        return Self.deduplicated(directories)
    }

    /// Default Homebrew prefixes: Apple Silicon, then Intel.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]

    private func nvmDirectories(root: String) -> [String] {
        versionDirectories(in: "\(root)/versions/node", suffix: "bin")
    }

    /// One bin directory per installed Node release, newest first.
    private func versionDirectories(in parent: String, suffix: String) -> [String] {
        listDirectory(parent)
            .filter { !$0.hasPrefix(".") }
            .sorted { Self.versionComponents($0).lexicographicallyPrecedes(Self.versionComponents($1)) }
            .reversed()
            .map { "\(parent)/\($0)/\(suffix)" }
    }

    static func versionComponents(_ name: String) -> [Int] {
        name.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func deduplicated(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.count > 1 && trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private func expandingTilde(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + path.dropFirst() }
        return path
    }

    /// Whether a picked file looks like the agent's CLI rather than something else carrying the
    /// vendor's name (upstream `cliPathMatchesAgent`).
    public static func path(_ path: String, matches descriptor: AgentDescriptor) -> Bool {
        guard let expected = descriptor.cliCommand else { return true }
        return (path as NSString).lastPathComponent.lowercased() == expected.lowercased()
    }
}

/// Remembers hits only, and drops a hit as soon as its file is gone: installing a CLI is picked up
/// on the next lookup and uninstalling it is never answered from the cache.
public final class LauncherCache: Sendable {
    private let resolver: LauncherResolver
    private let hits = Mutex<[String: String]>([:])
    private let stillExists: @Sendable (String) -> Bool

    public init(resolver: LauncherResolver = LauncherResolver(),
                stillExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.resolver = resolver
        self.stillExists = stillExists
    }

    public func resolve(_ command: String, override: String? = nil) -> String? {
        let key = "\(command)\u{0}\(override ?? "")"
        if let cached = hits.withLock({ $0[key] }), stillExists(cached) { return cached }
        let resolved = resolver.resolve(command, override: override)
        hits.withLock { $0[key] = resolved }
        return resolved
    }

    /// Forgets every hit (after an install or an override change).
    public func invalidate() {
        hits.withLock { $0.removeAll() }
    }

    public var searchDirectories: [String] { resolver.searchDirectories() }
}
