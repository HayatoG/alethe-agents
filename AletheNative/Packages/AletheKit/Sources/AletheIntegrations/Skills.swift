import Foundation

/// Where an agent keeps its skills (upstream `skills.rs` `ROOTS`). `shared` is the cross-agent store
/// the other roots link into, not an agent of its own.
public enum SkillAgent: String, CaseIterable, Codable, Hashable, Sendable {
    case claude, codex, opencode, antigravity, shared

    /// The skills folder relative to the home folder.
    public var segments: [String] {
        switch self {
        case .claude: [".claude", "skills"]
        case .codex: [".codex", "skills"]
        case .opencode: [".config", "opencode", "skill"]
        case .antigravity: [".gemini", "skills"]
        case .shared: [".agents", "skills"]
        }
    }
}

public struct SkillSummary: Hashable, Sendable, Identifiable {
    public var name: String
    public var agent: SkillAgent
    public var path: String
    /// The folder with symlinks resolved (the shared copy for a linked skill).
    public var resolvedPath: String
    public var description: String
    /// The skill folder is a symlink.
    public var linked: Bool
    /// An agent's entry whose folder lives in the shared store.
    public var shared: Bool
    /// Ships with the agent (Codex `.system`): never removed from Alethe.
    public var bundled: Bool
    public var entryCount: Int

    public var id: String { "\(agent.rawValue):\(path)" }

    public init(name: String, agent: SkillAgent, path: String, resolvedPath: String, description: String = "",
                linked: Bool = false, shared: Bool = false, bundled: Bool = false, entryCount: Int = 1) {
        self.name = name
        self.agent = agent
        self.path = path
        self.resolvedPath = resolvedPath
        self.description = description
        self.linked = linked
        self.shared = shared
        self.bundled = bundled
        self.entryCount = entryCount
    }
}

public struct SkillAgentSnapshot: Hashable, Sendable {
    public var agent: SkillAgent
    public var root: String
    public var exists: Bool
    public var skills: [SkillSummary]

    public init(agent: SkillAgent, root: String, exists: Bool, skills: [SkillSummary]) {
        self.agent = agent
        self.root = root
        self.exists = exists
        self.skills = skills
    }
}

/// A file or folder inside a skill (depth and width capped like upstream's `build_tree`).
public struct SkillNode: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var children: [SkillNode]
    /// Its folder had more entries than were listed.
    public var truncated: Bool

    public var id: String { path }
}

/// The skill's entry in `~/.agents/.skill-lock.json` (written by the `skills` installer).
public struct SkillLockInfo: Hashable, Sendable {
    public var source: String?
    public var sourceURL: String?
    public var installedAt: String?
    public var updatedAt: String?
}

public struct SkillDetail: Hashable, Sendable {
    public var summary: SkillSummary
    public var frontmatter: [String: String]
    public var frontmatterRaw: String
    /// `SKILL.md` without its frontmatter.
    public var body: String
    public var tree: [SkillNode]
    public var lock: SkillLockInfo?
}

public struct SkillRemoveReport: Hashable, Sendable {
    public var path: String
    /// Only the link went; the shared copy stays at `sharedCopyPath`.
    public var removedLinkOnly: Bool
    public var sharedCopyPath: String?
    /// The folder went to the Trash instead of being deleted.
    public var movedToTrash: Bool
}

public enum SkillError: Error, Equatable, Sendable {
    case invalidName
    case notFound
    case outsideRoot
    case bundled
    case removeFailed(String)
}

/// Reads, inspects and uninstalls the skills of every agent (upstream `skills.rs`). All work is
/// synchronous file I/O: callers use the `async` forms, which run it off the main thread and stop
/// between entries when their task is cancelled.
public struct SkillStore: Sendable {
    public static let skillFile = "SKILL.md"
    static let codexSystemMarker = ".codex-system-skills.marker"
    static let systemFolder = ".system"
    static let maxTreeDepth = 4
    static let maxTreeChildren = 100

    public let home: URL
    /// Real folders go to the Trash (links are always just unlinked).
    public let useTrash: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, useTrash: Bool = true) {
        self.home = home
        self.useTrash = useTrash
    }

    public func root(for agent: SkillAgent) -> URL {
        agent.segments.reduce(home) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    var lockFile: URL { home.appending(path: ".agents/.skill-lock.json") }

    // MARK: Async

    public func scan() async throws -> [SkillAgentSnapshot] {
        try await Self.offMain { try scanNow() }
    }

    public func detail(agent: SkillAgent, name: String) async throws -> SkillDetail {
        try await Self.offMain { try detailNow(agent: agent, name: name) }
    }

    public func uninstall(agent: SkillAgent, name: String) async throws -> SkillRemoveReport {
        try await Self.offMain { try uninstallNow(agent: agent, name: name) }
    }

    /// Runs `work` on a background task that inherits the caller's cancellation.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Scan

    public func scanNow() throws -> [SkillAgentSnapshot] {
        try SkillAgent.allCases.map { agent in
            try Task.checkCancellation()
            let root = root(for: agent)
            let exists = Self.isDirectory(root)
            return SkillAgentSnapshot(agent: agent, root: root.path, exists: exists,
                                      skills: exists ? try collect(agent, root: root) : [])
        }
    }

    private func collect(_ agent: SkillAgent, root: URL) throws -> [SkillSummary] {
        var out: [SkillSummary] = []
        for entry in Self.children(of: root) where Self.isDirectory(entry) {
            try Task.checkCancellation()
            let name = entry.lastPathComponent
            if name == Self.systemFolder {
                for nested in Self.children(of: entry) where Self.isDirectory(nested) {
                    if let summary = summarize(agent, root: root, dir: nested) { out.append(summary) }
                }
                continue
            }
            if name.hasPrefix(".") { continue }
            if let summary = summarize(agent, root: root, dir: entry) { out.append(summary) }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Nil when the folder has no readable `SKILL.md`.
    func summarize(_ agent: SkillAgent, root: URL, dir: URL) -> SkillSummary? {
        guard let raw = Self.readSkillFile(dir) else { return nil }
        let fields = SkillFrontmatter.parse(SkillFrontmatter.split(raw).front)
        let resolved = Self.canonical(dir)
        let inShared = Self.isInside(resolved, Self.canonical(self.root(for: .shared)))
        let bundled = dir.deletingLastPathComponent().lastPathComponent == Self.systemFolder
            || Self.hasBundledMarker(dir, root: root)
        return SkillSummary(
            name: dir.lastPathComponent, agent: agent, path: dir.path, resolvedPath: resolved.path,
            description: fields["description"] ?? "", linked: Self.isLink(dir),
            shared: inShared && agent != .shared, bundled: bundled,
            entryCount: Self.children(of: dir, includingHidden: true).count
        )
    }

    // MARK: Detail

    public func detailNow(agent: SkillAgent, name: String) throws -> SkillDetail {
        let (root, dir) = try locate(agent, name)
        guard let summary = summarize(agent, root: root, dir: dir), let raw = Self.readSkillFile(dir) else {
            throw SkillError.notFound
        }
        let parts = SkillFrontmatter.split(raw)
        try Task.checkCancellation()
        return SkillDetail(summary: summary, frontmatter: SkillFrontmatter.parse(parts.front),
                           frontmatterRaw: parts.front, body: parts.body, tree: try Self.tree(dir, depth: 0),
                           lock: lockInfo(summary.name))
    }

    static func tree(_ dir: URL, depth: Int) throws -> [SkillNode] {
        guard depth < maxTreeDepth else { return [] }
        try Task.checkCancellation()
        let items = children(of: dir, includingHidden: true)
            .map { (url: $0, isDirectory: isDirectory($0)) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.lowercased() < rhs.url.lastPathComponent.lowercased()
            }
        let truncated = items.count > maxTreeChildren
        return try items.prefix(maxTreeChildren).map { item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? NSNumber)?.int64Value
            return SkillNode(name: item.url.lastPathComponent, path: item.url.path, isDirectory: item.isDirectory,
                             size: size ?? 0,
                             children: item.isDirectory ? try tree(item.url, depth: depth + 1) : [],
                             truncated: truncated)
        }
    }

    func lockInfo(_ name: String) -> SkillLockInfo? {
        guard let data = try? Data(contentsOf: lockFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = object["skills"] as? [String: Any],
              let entry = skills[name] as? [String: Any] else { return nil }
        return SkillLockInfo(source: entry["source"] as? String, sourceURL: entry["sourceUrl"] as? String,
                             installedAt: entry["installedAt"] as? String, updatedAt: entry["updatedAt"] as? String)
    }

    // MARK: Uninstall

    public func uninstallNow(agent: SkillAgent, name: String) throws -> SkillRemoveReport {
        let (root, dir) = try locate(agent, name)
        guard let summary = summarize(agent, root: root, dir: dir) else { throw SkillError.notFound }
        guard !summary.bundled else { throw SkillError.bundled }
        try Task.checkCancellation()
        do {
            if summary.linked {
                // Unlinked, never followed: the shared copy other agents point at has to survive.
                try FileManager.default.removeItem(atPath: dir.path)
                return SkillRemoveReport(path: summary.path, removedLinkOnly: true,
                                         sharedCopyPath: summary.resolvedPath, movedToTrash: false)
            }
            var trashed = false
            if useTrash {
                trashed = (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) != nil
            }
            if !trashed { try FileManager.default.removeItem(atPath: dir.path) }
            return SkillRemoveReport(path: summary.path, removedLinkOnly: false, sharedCopyPath: nil,
                                     movedToTrash: trashed)
        } catch {
            throw SkillError.removeFailed(error.localizedDescription)
        }
    }

    // MARK: Paths

    /// Rejects names that could leave the skills folder (upstream `validate_name`).
    public static func validate(name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == "." || name == ".."
            || name.contains(where: { "/\\:".contains($0) }) || name.contains("\0") {
            throw SkillError.invalidName
        }
    }

    /// `<root>/<name>` or `<root>/.system/<name>`, proven not to escape the root, so a crafted name
    /// can never point the reader or the uninstaller somewhere else.
    func locate(_ agent: SkillAgent, _ name: String) throws -> (root: URL, dir: URL) {
        try Self.validate(name: name)
        let root = root(for: agent)
        // No trailing slash: a path ending in "/" would follow a linked skill instead of naming the link.
        let direct = root.appending(path: name, directoryHint: .notDirectory)
        let system = root.appending(path: Self.systemFolder).appending(path: name, directoryHint: .notDirectory)
        let dir: URL
        if Self.isDirectory(direct) {
            dir = direct
        } else if Self.isDirectory(system) {
            dir = system
        } else {
            throw SkillError.notFound
        }
        guard Self.isInside(Self.canonical(dir.deletingLastPathComponent()), Self.canonical(root)) else {
            throw SkillError.outsideRoot
        }
        return (root, dir)
    }

    static func readSkillFile(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appending(path: skillFile), encoding: .utf8)
    }

    static func hasBundledMarker(_ dir: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        var cursor = dir.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: cursor.appending(path: codexSystemMarker).path) { return true }
            if cursor.path == rootPath || cursor.path == "/" { return false }
            cursor = cursor.deletingLastPathComponent()
        }
    }

    /// Follows symlinks, like upstream's `Path::is_dir`.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func children(of dir: URL, includingHidden: Bool = true) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: options)) ?? []
    }

    /// `realpath`: symlinks resolved and `/tmp` spelled `/private/tmp` (Foundation's
    /// `resolvingSymlinksInPath` does the opposite, which breaks prefix checks).
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    static func isInside(_ path: URL, _ root: URL) -> Bool {
        path.pathComponents.starts(with: root.pathComponents)
    }
}

/// `SKILL.md` frontmatter, parsed for the shapes installed skills actually use (upstream
/// `split_frontmatter`/`parse_frontmatter`): plain and quoted scalars, folded (`>`) and literal (`|`)
/// blocks, and nested maps kept as their indented text. Not a YAML parser.
public enum SkillFrontmatter {
    public static func split(_ raw: String) -> (front: String, body: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ("", normalized) }
        let rest = normalized.dropFirst(4)
        if rest.hasPrefix("---") {
            return ("", trimBody(rest.dropFirst(3)))
        }
        guard let fence = rest.range(of: "\n---") else { return ("", normalized) }
        return (String(rest[..<fence.lowerBound]), trimBody(rest[fence.upperBound...]))
    }

    private static func trimBody(_ body: Substring) -> String {
        String(body.drop(while: \.isWhitespace))
    }

    public static func parse(_ front: String) -> [String: String] {
        let lines = front.components(separatedBy: "\n")
        var out: [String: String] = [:]
        var index = 0
        func indented(_ line: String) -> Bool { line.first == " " || line.first == "\t" }

        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || indented(line)
                || line.first == "#" || line.first == "-" { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            var block: [String] = []
            if rest.isEmpty || rest.hasPrefix(">") || rest.hasPrefix("|") {
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1
                        continue
                    }
                    guard indented(next) else { break }
                    block.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
            }
            out[key] = block.isEmpty ? unquote(rest)
                : block.joined(separator: rest.hasPrefix("|") ? "\n" : " ")
        }
        return out
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where trimmed.count >= 2 && trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

/// One skill across the agents that have it (upstream `lib/skills.ts` `groupSkillsByName`).
public struct SkillGroup: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var entries: [SkillSummary]
    /// Agents that have it, without the shared store.
    public var agents: [SkillAgent]
    /// Entries a bulk remove may touch: never the shared copy other agents link to, never bundled.
    public var removable: [SkillSummary]
    public var sharedEntry: SkillSummary?
    /// Every agent copy ships with its agent.
    public var bundled: Bool

    public var id: String { name }

    public static func group(_ snapshots: [SkillAgentSnapshot]) -> [SkillGroup] {
        var byName: [String: [SkillSummary]] = [:]
        var order: [String] = []
        for skill in snapshots.flatMap(\.skills) {
            if byName[skill.name] == nil { order.append(skill.name) }
            byName[skill.name, default: []].append(skill)
        }
        return order.map { name in
            let entries = byName[name] ?? []
            let agentEntries = entries.filter { $0.agent != .shared }
            return SkillGroup(
                name: name,
                description: entries.first { !$0.description.isEmpty }?.description ?? "",
                entries: entries,
                agents: agentEntries.map(\.agent),
                removable: agentEntries.filter { !$0.bundled },
                sharedEntry: entries.first { $0.agent == .shared },
                bundled: !agentEntries.isEmpty && agentEntries.allSatisfy(\.bundled)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Name or description contains the query (case-insensitive); an empty query matches all.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle) || description.localizedCaseInsensitiveContains(needle)
    }

    /// Installed for `agent` (nil: any).
    public func isInstalled(for agent: SkillAgent?) -> Bool {
        agent.map { agent in entries.contains { $0.agent == agent } } ?? true
    }
}
