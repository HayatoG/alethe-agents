import Foundation

/// A frontend call to an API path (upstream `ApiCallSite`).
public struct ApiCallSite: Codable, Hashable, Sendable {
    public var file: String
    public var line: Int
    public var method: String?
    public var pathPattern: String

    public init(file: String, line: Int, method: String?, pathPattern: String) {
        self.file = file
        self.line = line
        self.method = method
        self.pathPattern = pathPattern
    }
}

/// A backend route declaration (upstream `ApiRouteSite`).
public struct ApiRouteSite: Codable, Hashable, Sendable {
    public var file: String
    public var line: Int
    public var method: String?
    public var pathPattern: String
    public var framework: String

    public init(file: String, line: Int, method: String?, pathPattern: String, framework: String) {
        self.file = file
        self.line = line
        self.method = method
        self.pathPattern = pathPattern
        self.framework = framework
    }
}

/// A call with no related backend route (upstream `ContractWarning`).
public struct ContractWarning: Codable, Hashable, Sendable {
    public var call: ApiCallSite
    public var reason: String

    public init(call: ApiCallSite, reason: String) {
        self.call = call
        self.reason = reason
    }
}

public enum ContractCheckError: Error, Equatable, Sendable {
    case environmentNotFound
}

/// Port of upstream `contract_check.rs` (Merge Center shield layer 3): a heuristic that matches
/// frontend `fetch`/`axios` calls against Express/FastAPI/Axum routes with simple line regexes.
/// Best-effort and never blocking; silent when no backend route is found at all.
public enum ContractCheck {
    public static let skipDirectories: Set<String> = [
        "node_modules", ".git", "target", "dist", "build", ".next", ".venv", "venv", "__pycache__",
        ".alethe", "graphify-out",
    ]
    static let frontendExtensions: Set<String> = ["ts", "tsx", "js", "jsx"]
    static let backendExtensions: Set<String> = ["py", "js", "ts", "rs"]

    private struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression
        let methodGroup: Int?
        let pathGroup: Int
        let framework: String

        init(_ pattern: String, method: Int?, path: Int, framework: String = "") {
            // Patterns are constants; a failure here is a programming error.
            regex = try! NSRegularExpression(pattern: pattern)
            methodGroup = method
            pathGroup = path
            self.framework = framework
        }
    }

    private static let parameter = try! NSRegularExpression(
        pattern: #"(:[A-Za-z0-9_]+|\{[A-Za-z0-9_:]+\}|<[A-Za-z0-9_:]+>)"#)

    private static let callPatterns = [
        Pattern(#"fetch\(\s*['"`]([^'"`]+)"#, method: nil, path: 1),
        Pattern(#"axios\.(get|post|put|delete|patch)\(\s*['"`]([^'"`]+)"#, method: 1, path: 2),
    ]

    private static let routePatterns = [
        Pattern(#"(?:app|router)\.(get|post|put|delete|patch)\(\s*['"`]([^'"`]+)"#, method: 1, path: 2, framework: "express"),
        Pattern(#"@(?:app|router)\.(get|post|put|delete|patch)\(\s*['"`]([^'"`]+)"#, method: 1, path: 2, framework: "fastapi"),
        Pattern(#"\.route\(\s*['"`]([^'"`]+)"#, method: nil, path: 1, framework: "axum"),
    ]

    // MARK: Pure helpers

    /// `:id`, `{id}` and `<id>` become `:param`; a trailing slash is dropped (`/` stays `/`).
    public static func normalizePathPattern(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let normalized = parameter.stringByReplacingMatches(in: raw, range: range, withTemplate: ":param")
        var trimmed = Substring(normalized)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.isEmpty ? "/" : String(trimmed)
    }

    static func segmentPrefix(_ path: String, _ count: Int) -> [Substring] {
        var rest = Substring(path)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        return Array(rest.split(separator: "/", omittingEmptySubsequences: false).prefix(count))
    }

    /// Equal, one a prefix of the other, or sharing the first two segments (so `/api/v2/x` against
    /// `/api/v1/x` is still flagged: the version segment differs).
    public static func pathsRelated(_ call: String, _ route: String) -> Bool {
        if call.isEmpty || route.isEmpty { return false }
        if call == route || call.hasPrefix(route) || route.hasPrefix(call) { return true }
        let callPrefix = segmentPrefix(call, 2)
        return !callPrefix.isEmpty && callPrefix == segmentPrefix(route, 2)
    }

    /// Frontend calls in one file's text (first match per pattern per line, relative paths only).
    public static func calls(in text: String, file: String) -> [ApiCallSite] {
        scan(text, patterns: callPatterns).map {
            ApiCallSite(file: file, line: $0.line, method: $0.method, pathPattern: $0.path)
        }
    }

    /// Backend routes in one file's text.
    public static func routes(in text: String, file: String) -> [ApiRouteSite] {
        scan(text, patterns: routePatterns).map {
            ApiRouteSite(file: file, line: $0.line, method: $0.method, pathPattern: $0.path, framework: $0.framework)
        }
    }

    /// Calls with no related route; empty when there are no routes (nothing to compare against).
    public static func warnings(calls: [ApiCallSite], routes: [ApiRouteSite]) -> [ContractWarning] {
        guard !routes.isEmpty else { return [] }
        return calls
            .filter { call in !routes.contains { pathsRelated(call.pathPattern, $0.pathPattern) } }
            .map { ContractWarning(call: $0, reason: reason(for: $0.pathPattern)) }
    }

    public static func reason(for path: String) -> String {
        "No backend route found for \"\(path)\" (check that the endpoint exists)"
    }

    private static func scan(_ text: String, patterns: [Pattern]) -> [(line: Int, method: String?, path: String, framework: String)] {
        var found: [(Int, String?, String, String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(line.hasSuffix("\r") ? line.dropLast() : line)
            let range = NSRange(line.startIndex..., in: line)
            for pattern in patterns {
                guard let match = pattern.regex.firstMatch(in: line, range: range),
                      let pathRange = Range(match.range(at: pattern.pathGroup), in: line) else { continue }
                let raw = String(line[pathRange])
                guard raw.hasPrefix("/") else { continue }
                let method = pattern.methodGroup
                    .flatMap { Range(match.range(at: $0), in: line) }
                    .map { line[$0].uppercased() }
                found.append((index + 1, method, normalizePathPattern(raw), pattern.framework))
            }
        }
        return found
    }

    // MARK: Filesystem

    /// Files under `root` with one of `extensions`, skipping build/vendor folders; sorted.
    static func files(under root: URL, extensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var stack = [root]
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if !skipDirectories.contains(entry.lastPathComponent) { stack.append(entry) }
                } else if extensions.contains(entry.pathExtension) {
                    result.append(entry)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func relative(_ file: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    /// Runs the check over a checkout (upstream `contract_check(env_path)`).
    public static func check(root: URL) throws -> [ContractWarning] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ContractCheckError.environmentNotFound
        }
        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        let calls = files(under: root, extensions: frontendExtensions).flatMap { url in
            text(url).map { Self.calls(in: $0, file: relative(url, to: root)) } ?? []
        }
        let routes = files(under: root, extensions: backendExtensions).flatMap { url in
            text(url).map { Self.routes(in: $0, file: relative(url, to: root)) } ?? []
        }
        return warnings(calls: calls, routes: routes)
    }
}
