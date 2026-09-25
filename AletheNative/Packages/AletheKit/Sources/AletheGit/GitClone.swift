import Foundation

/// Clone URLs as the New Project sheet takes them (upstream `projects.rs`).
public enum GitCloneURL {
    /// `owner/repo` and `github.com/owner/repo` become https GitHub URLs; full URLs, `git@` remotes
    /// and local paths are kept (upstream `normalize_github_url`, plus local paths for bare repos).
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = ["http://", "https://", "git@", "ssh://", "git://", "file://", "/", "~/"]
        if kept.contains(where: { trimmed.hasPrefix($0) }) { return trimmed }
        if trimmed.hasPrefix("github.com/") { return "https://\(trimmed)" }
        if trimmed.contains("/"), !trimmed.contains(" ") { return "https://github.com/\(trimmed)" }
        return trimmed
    }

    /// Whether git may be handed `url`: known transports only (no `ext::` helpers) and nothing that
    /// reads as an option.
    public static func isCloneable(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains("\n"), !url.contains("::") else { return false }
        if url.hasPrefix("/") { return true }
        if url.hasPrefix("git@") { return url.contains(":") && url.count > 5 }
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ssh", "git": return !(components.host ?? "").isEmpty
        case "file": return !components.path.isEmpty
        default: return false
        }
    }

    /// The folder a clone lands in: the repository's name, sanitized (upstream `repo_folder_name`).
    public static func folderName(for url: String) -> String {
        var name = url
        while name.hasSuffix("/") { name.removeLast() }
        name = String(name.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == ":" }.last ?? "")
        while name.hasSuffix(".git") { name.removeLast(4) }
        let sanitized = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "repo" : sanitized
    }

    /// Where to clone: the chosen folder is the parent, unless it is already named after the
    /// repository; nothing chosen means `~/Alethe` (upstream `resolve_clone_target`).
    public static func target(requested: String, url: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = folderName(for: url)
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: URL
        if trimmed.isEmpty {
            base = home.appending(path: "Alethe", directoryHint: .isDirectory)
        } else if trimmed == "~" || trimmed.hasPrefix("~/") {
            base = home.appending(path: String(trimmed.dropFirst(min(2, trimmed.count))), directoryHint: .isDirectory)
        } else {
            base = URL(filePath: trimmed, directoryHint: .isDirectory)
        }
        let standardized = base.standardizedFileURL
        return standardized.lastPathComponent == folder
            ? standardized
            : standardized.appending(path: folder, directoryHint: .isDirectory)
    }

    /// The web page of a hosted remote (`git@host:owner/repo.git`, `ssh://git@host/owner/repo`,
    /// `https://user@host/owner/repo.git`), without credentials or `.git`; nil for local remotes.
    public static func webURL(forRemote remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if trimmed.hasPrefix("git@") {
            let rest = trimmed.dropFirst(4)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            host = String(rest[..<colon])
            path = String(rest[rest.index(after: colon)...])
        } else if let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(), ["http", "https", "ssh", "git"].contains(scheme),
                  let found = components.host, !found.isEmpty {
            host = found
            path = components.path
        } else {
            return nil
        }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty, !host.contains("/") else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }
}

extension GitCloneURL {
    /// The page Open in Browser shows for a project (P5-5 clone URL first, else its `origin`).
    public static func projectWebURL(cloneURL: String?, originRemote: String?) -> URL? {
        cloneURL.flatMap(webURL(forRemote:)) ?? originRemote.flatMap(webURL(forRemote:))
    }
}

/// One line of `git clone --progress` (`Receiving objects:  45% (450/1000)`).
public struct GitCloneProgress: Equatable, Sendable {
    public var phase: String
    public var percent: Int?

    public init(phase: String, percent: Int?) {
        self.phase = phase
        self.percent = percent
    }

    public static func parse(_ line: String) -> GitCloneProgress? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("remote:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !phase.isEmpty, phase.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber }
        let percent = rest.dropFirst(digits.count).first == "%" ? Int(digits) : nil
        return GitCloneProgress(phase: phase, percent: percent)
    }
}

public enum GitCloneError: Error, Equatable, Sendable {
    case invalidURL(String)
    /// The target folder exists and is not empty.
    case targetExists(String)
}

/// `git clone` with progress (upstream `clone_github_repo`, shallow as upstream). A failed or
/// cancelled clone removes the partial folder it created.
public struct GitCloner: Sendable {
    public var runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    public func clone(
        _ url: String,
        into target: URL,
        shallow: Bool = true,
        onProgress: (@Sendable (GitCloneProgress) -> Void)? = nil
    ) async throws -> URL {
        guard GitCloneURL.isCloneable(url) else { throw GitCloneError.invalidURL(url) }
        let fm = FileManager.default
        let target = target.standardizedFileURL
        let existed = fm.fileExists(atPath: target.path)
        if existed, !((try? fm.contentsOfDirectory(atPath: target.path))?.isEmpty ?? false) {
            throw GitCloneError.targetExists(target.path)
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var arguments = ["clone", "--progress"]
        // A local path ignores --depth with a warning; the file:// form honors it but is slower.
        if shallow, !url.hasPrefix("/") { arguments += ["--depth", "1"] }
        arguments += ["--", url, target.path]
        var lineHandler: (@Sendable (String) -> Void)?
        if let onProgress {
            lineHandler = { line in
                if let progress = GitCloneProgress.parse(line) { onProgress(progress) }
            }
        }
        do {
            _ = try await runner.run(arguments, in: parent, onProgress: lineHandler)
        } catch {
            if existed {
                // Keep the (empty) folder the user chose; drop what git wrote into it.
                for item in (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: item)
                }
            } else {
                try? fm.removeItem(at: target)
            }
            throw error
        }
        return target
    }
}
