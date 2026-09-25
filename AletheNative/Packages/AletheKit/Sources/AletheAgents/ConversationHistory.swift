import Foundation

/// Reads a JSONL file line by line without loading it: transcripts run to many MB, and a single
/// line (a pasted file, a tool result) can be huge. Lines past `maxLineBytes` are skipped whole.
public enum JSONLReader {
    public static let maxLineBytes = 4 << 20

    /// Calls `body` with each line's data until it returns false or `maxLines` lines were read.
    public static func forEachLine(atPath path: String, maxLines: Int = .max, _ body: (Data) -> Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var pending = Data()
        var oversized = false
        var lines = 0
        while lines < maxLines, let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if !oversized { pending.append(chunk[start..<newline]) }
                if !oversized, !pending.isEmpty {
                    lines += 1
                    if !body(pending) || lines >= maxLines { return }
                }
                pending.removeAll(keepingCapacity: true)
                oversized = false
                start = chunk.index(after: newline)
            }
            if !oversized {
                pending.append(chunk[start...])
                if pending.count > maxLineBytes {
                    oversized = true
                    pending.removeAll()
                }
            }
        }
        if !oversized, !pending.isEmpty, lines < maxLines { _ = body(pending) }
    }

    public static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// One past conversation, as the history sheet lists it (upstream `ClaudeSessionMeta`).
public struct ConversationSummary: Hashable, Sendable, Identifiable {
    public var id: String
    /// Claude Code's generated title (`ai-title`); nil for Codex.
    public var title: String?
    public var firstPrompt: String?
    /// User and assistant messages; nil when not counted (Codex).
    public var messageCount: Int?
    public var modifiedAt: Date
    public var sizeBytes: Int64

    public init(id: String, title: String? = nil, firstPrompt: String? = nil, messageCount: Int? = nil,
                modifiedAt: Date, sizeBytes: Int64) {
        self.id = id
        self.title = title
        self.firstPrompt = firstPrompt
        self.messageCount = messageCount
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }

    /// What a row shows first.
    public var displayTitle: String? { title ?? firstPrompt }
}

public enum ConversationHistory {
    static let promptLimit = 240

    static func truncated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > promptLimit ? String(trimmed.prefix(promptLimit - 1)) + "…" : trimmed
    }

    /// Claude Code conversations of a folder, newest first (upstream `list_claude_sessions`).
    public static func claude(cwd: String, homeDirectory: String = NSHomeDirectory()) -> [ConversationSummary] {
        let projects = "\(homeDirectory)/.claude/projects"
        let names = Set([cwd, SessionPaths.normalize(cwd)].filter { !$0.isEmpty }.map(ClaudeSessions.projectFolderName(for:)))
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [])
            .filter { folder in names.contains { $0.caseInsensitiveCompare(folder) == .orderedSame } }
        var seen = Set<String>()
        var result: [ConversationSummary] = []
        for folder in folders {
            let directory = "\(projects)/\(folder)"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(".jsonl".count))
                guard seen.insert(id).inserted else { continue }
                result.append(claudeSummary(id: id, path: "\(directory)/\(name)"))
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// One Claude transcript: its title, first prompt and message count.
    public static func claudeSummary(id: String, path: String) -> ConversationSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        var title: String?, prompt: String?, count = 0
        let userType = Data(#""type":"user""#.utf8), assistantType = Data(#""type":"assistant""#.utf8)
        let titleType = Data(#""type":"ai-title""#.utf8)
        JSONLReader.forEachLine(atPath: path) { line in
            // Byte probes first: a full parse of every record would allocate the whole transcript.
            if line.range(of: assistantType) != nil {
                count += 1
            } else if line.range(of: userType) != nil {
                count += 1
                if prompt == nil, let object = JSONLReader.object(line), let text = firstText(of: object["message"]) {
                    prompt = truncated(text)
                }
            } else if title == nil, line.range(of: titleType) != nil, let object = JSONLReader.object(line),
                      let value = (object["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty {
                title = value
            }
            return true
        }
        return ConversationSummary(id: id, title: title, firstPrompt: prompt, messageCount: count,
                                   modifiedAt: attributes?[.modificationDate] as? Date ?? .distantPast,
                                   sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// The first text of a message's content (a string or blocks).
    static func firstText(of message: Any?) -> String? {
        let content = (message as? [String: Any])?["content"]
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.lazy.compactMap { $0["text"] as? String }.first
    }

    /// Codex conversations of a folder, newest first, titled by their first real user turn (upstream
    /// `get_codex_session_title`: injected `<tag>` blocks are skipped; 200 lines at most).
    public static func codex(cwd: String, homeDirectory: String = NSHomeDirectory()) -> [ConversationSummary] {
        let target = SessionPaths.normalize(cwd)
        let root = "\(homeDirectory)/.codex/sessions"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var seen = Set<String>()
        var result: [ConversationSummary] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".jsonl") else { continue }
            let path = "\(root)/\(relative)"
            guard let meta = CodexSessions.sessionMeta(atPath: path), SessionPaths.normalize(meta.cwd) == target,
                  seen.insert(meta.id).inserted else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            result.append(ConversationSummary(id: meta.id, firstPrompt: codexFirstPrompt(atPath: path),
                                              modifiedAt: attributes?[.modificationDate] as? Date ?? .distantPast,
                                              sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func codexFirstPrompt(atPath path: String) -> String? {
        var found: String?
        JSONLReader.forEachLine(atPath: path, maxLines: 200) { line in
            found = codexUserText(line)
            return found == nil
        }
        return found.map(truncated)
    }

    static func codexUserText(_ line: Data) -> String? {
        guard let object = JSONLReader.object(line), object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
              payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] else { return nil }
        return blocks.lazy.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("<") }
    }

    /// Conversations of an agent in a folder (Claude Code and Codex keep readable transcripts).
    public static func list(_ kind: AgentKind, cwd: String) -> [ConversationSummary] {
        switch kind {
        case .claude: claude(cwd: cwd)
        case .codex: codex(cwd: cwd)
        default: []
        }
    }
}
