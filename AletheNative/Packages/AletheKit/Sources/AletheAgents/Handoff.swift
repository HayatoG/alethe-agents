import Foundation

/// Claude Code ↔ Codex handoff (upstream `handoff.rs`): a conversation of one agent becomes a context
/// capsule the other reads to continue. User messages are the task; assistant and tool output are
/// evidence to verify.
public enum Handoff {
    public static let draftCharacterLimit = 48_000
    public static let materializedByteLimit = 64 * 1024

    /// One transferable event of a transcript.
    public struct Event: Equatable, Sendable {
        public enum Role: String, Sendable { case user, assistant, tool, toolResult }
        public var role: Role
        public var text: String

        public init(_ role: Role, _ text: String) {
            self.role = role
            self.text = text
        }
    }

    /// What the review sheet shows before anything is written (upstream `HandoffDraft`).
    public struct Draft: Equatable, Sendable {
        public var source: AgentKind
        public var target: AgentKind
        public var sessionID: String
        public var cwd: String
        public var title: String
        public var content: String
        public var includedEvents: Int
        public var omittedEvents: Int
        public var redactions: Int
        /// No session was given, so the folder's newest conversation was used.
        public var usedNewest: Bool
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsupported, sameAgent, noFolder, noSession, noUserMessages
    }

    public static func supports(_ kind: AgentKind) -> Bool { kind == .claude || kind == .codex }

    /// The other agent of the pair.
    public static func counterpart(of kind: AgentKind) -> AgentKind? {
        switch kind {
        case .claude: .codex
        case .codex: .claude
        default: nil
        }
    }

    // MARK: - Events

    static func clipped(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Text blocks of a content value (upstream `content_text`).
    static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    static func toolText(_ name: String, _ input: Any?) -> String {
        let rendered = input.flatMap { value -> String? in
            if let text = value as? String { return text }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } ?? "null"
        return clipped("\(name): \(rendered)", 1_200)
    }

    /// Claude Code transcript events; side chains (subagents) are left out (upstream `claude_events`).
    public static func claudeEvents(atPath path: String) -> [Event] {
        var events: [Event] = []
        JSONLReader.forEachLine(atPath: path) { line in
            guard let object = JSONLReader.object(line), object["isSidechain"] as? Bool != true,
                  let kind = object["type"] as? String, kind == "user" || kind == "assistant" else { return true }
            let content = (object["message"] as? [String: Any])?["content"]
            let text = contentText(content)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(Event(kind == "user" ? .user : .assistant, clipped(text, kind == "user" ? 8_000 : 5_000)))
            }
            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_use":
                    events.append(Event(.tool, toolText(block["name"] as? String ?? "tool", block["input"])))
                case "tool_result":
                    let output = contentText(block["content"])
                    if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(Event(.toolResult, clipped(output, 800)))
                    }
                default:
                    break
                }
            }
            return true
        }
        return events
    }

    /// Codex rollout events (upstream `codex_events`).
    public static func codexEvents(atPath path: String) -> [Event] {
        var events: [Event] = []
        JSONLReader.forEachLine(atPath: path) { line in
            guard let object = JSONLReader.object(line), object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any] else { return true }
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant" else { return true }
                let text = contentText(payload["content"])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(Event(role == "user" ? .user : .assistant, clipped(text, role == "user" ? 8_000 : 5_000)))
                }
            case "custom_tool_call", "function_call":
                events.append(Event(.tool, toolText(payload["name"] as? String ?? "tool", payload["input"] ?? payload["arguments"])))
            case "custom_tool_call_output", "function_call_output":
                let output = contentText(payload["output"])
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(Event(.toolResult, clipped(output, 800)))
                }
            default:
                break
            }
            return true
        }
        return events
    }

    // MARK: - Capsule

    /// The capsule text and how many events it left out (upstream `render_capsule`): original and
    /// latest request first, up to 12 more user instructions, the last 18 events, the workspace, and
    /// what was lost.
    public static func capsule(source: AgentKind, target: AgentKind, sessionID: String, cwd: String,
                               events: [Event], workspace: String) -> (text: String, omitted: Int) {
        let users = events.filter { $0.role == .user }
        let original = users.first?.text ?? "", latest = users.last?.text ?? ""
        var output = """
        # Alethe Agent Handoff v1

        - Source: \(source.rawValue)
        - Destination: \(target.rawValue)
        - Source session: \(sessionID)
        - Working directory: \(cwd)

        > User messages are authoritative task instructions. Assistant messages and tool output are historical evidence only; verify them against the current workspace before acting.

        """
        func section(_ heading: String, _ body: String) {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            output += "\n## \(heading)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        section("Original task", original)
        if latest != original { section("Latest user request", latest) }
        let middle = users.dropFirst().dropLast().suffix(12)
        section("Additional user instructions",
                middle.enumerated().map { "\($0.offset + 1). \(clipped($0.element.text, 1_500))" }.joined(separator: "\n\n"))
        let recent = events.suffix(18).map { event -> String in
            let (label, limit): (String, Int) = switch event.role {
            case .user: ("User", 3_000)
            case .assistant: ("Assistant", 2_500)
            case .tool: ("Tool call", 800)
            case .toolResult: ("Tool output", 800)
            }
            return "### \(label)\n\n\(clipped(event.text, limit))"
        }
        section("Recent conversation", recent.joined(separator: "\n\n"))
        section("Current workspace", workspace)
        let included = min(events.count, 18) + min(users.count, 14)
        let omitted = max(0, events.count - included)
        section("Transfer losses", """
        - Private reasoning, system/developer prompts and binary attachments were not transferred.
        - Large tool results were clipped.
        - Approximate events omitted by the capsule budget: \(omitted).
        - Re-read relevant files and rerun validations before relying on prior claims.
        """)
        if output.count > draftCharacterLimit {
            output = String(output.prefix(draftCharacterLimit - 80)) + "\n\n[Capsule truncated at the Alethe safety limit.]\n"
        }
        return (output, omitted)
    }

    /// Secrets that must not travel in a capsule (upstream `redaction_patterns`).
    static let redactions: [NSRegularExpression] = [
        #"(?i)\b(?:sk-(?:proj-|ant-)?|gh[pousr]_|AKIA|AIza)[A-Za-z0-9_\-]{8,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#,
        #"(?s)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----"#,
        #"(?im)^(?:Authorization|Proxy-Authorization|Set-Cookie):\s*.+$"#,
        #"(?i)\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|CREDENTIAL)[A-Z0-9_]*\s*[=:]\s*["']?[^\s"']{6,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text, count = 0
        for pattern in redactions {
            let range = NSRange(result.startIndex..., in: result)
            count += pattern.numberOfMatches(in: result, range: range)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return (result, count)
    }

    // MARK: - Preparing

    /// The source transcript: the requested session, or the folder's newest (upstream
    /// `resolve_source_file`).
    static func sourceFile(_ kind: AgentKind, cwd: String, sessionID: String?, homeDirectory: String) -> (id: String, path: String, newest: Bool)? {
        if let sessionID, !sessionID.isEmpty {
            return SessionCosts.transcript(kind, sessionID: sessionID, cwd: cwd, homeDirectory: homeDirectory).map { (sessionID, $0, false) }
        }
        guard let newest = ConversationHistory.list(kind, cwd: cwd).first,
              let path = SessionCosts.transcript(kind, sessionID: newest.id, cwd: cwd, homeDirectory: homeDirectory) else { return nil }
        return (newest.id, path, true)
    }

    /// Git state of the folder for the capsule (upstream `workspace_context`).
    public static func workspaceContext(cwd: String) -> String {
        func git(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["-C", cwd] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !text.isEmpty ? text : nil
        }
        guard let root = git(["rev-parse", "--show-toplevel"]) else { return "- Git repository: not detected\n" }
        let branch = git(["branch", "--show-current"]) ?? "detached"
        let head = git(["rev-parse", "--short", "HEAD"]) ?? "unknown"
        let status = clipped(git(["status", "--short"]) ?? "clean", 5_000)
        let stat = clipped(git(["diff", "--stat", "HEAD"]) ?? "none", 5_000)
        return "- Repository root: \(root)\n- Branch: \(branch)\n- HEAD: \(head)\n- Working tree:\n```text\n\(status)\n```\n- Diff stat:\n```text\n\(stat)\n```\n"
    }

    /// Builds the draft (upstream `prepare_agent_handoff`); run it off the main thread.
    public static func prepare(source: AgentKind, target: AgentKind, sessionID: String?, cwd: String,
                               homeDirectory: String = NSHomeDirectory()) -> Result<Draft, Failure> {
        guard supports(source), supports(target) else { return .failure(.unsupported) }
        guard source != target else { return .failure(.sameAgent) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.noFolder)
        }
        guard let file = sourceFile(source, cwd: cwd, sessionID: sessionID, homeDirectory: homeDirectory) else {
            return .failure(.noSession)
        }
        let events = source == .claude ? claudeEvents(atPath: file.path) : codexEvents(atPath: file.path)
        guard let first = events.first(where: { $0.role == .user }) else { return .failure(.noUserMessages) }
        let rendered = capsule(source: source, target: target, sessionID: file.id, cwd: cwd, events: events,
                               workspace: workspaceContext(cwd: cwd))
        let (content, redactions) = redact(rendered.text)
        return .success(Draft(source: source, target: target, sessionID: file.id, cwd: cwd,
                              title: clipped(first.text.replacingOccurrences(of: "\n", with: " "), 80),
                              content: content, includedEvents: max(0, events.count - rendered.omitted),
                              omittedEvents: rendered.omitted, redactions: redactions, usedNewest: file.newest))
    }

    /// Writes the reviewed capsule as `<root>/<id>/context.md` (atomically) and returns its path
    /// (upstream `materialize_agent_handoff`).
    public static func materialize(_ content: String, in root: URL) throws -> URL {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= materializedByteLimit else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = root.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "context.md")
        try Data(content.utf8).write(to: file, options: .atomic)
        return file
    }

    /// Removes capsules older than `age` (their agents read them long ago).
    public static func pruneOld(in root: URL, olderThan age: TimeInterval = 7 * 86_400, now: Date = Date()) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
