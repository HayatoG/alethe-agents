import Foundation

/// OpenCode's sessions, from `opencode session list --format json` run in the folder (upstream
/// `snapshot_opencode_sessions`).
public enum OpenCodeSessions {
    /// Sessions of `cwd` in the CLI's JSON, newest first. Entries of another directory are skipped;
    /// `updated` is in milliseconds.
    public static func parse(_ json: String, cwd: String) -> [SessionSnapshot] {
        guard let start = json.firstIndex(of: "["),
              let entries = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [[String: Any]] else { return [] }
        let target = SessionPaths.normalize(cwd)
        return entries.compactMap { entry -> SessionSnapshot? in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let updated = (entry["updated"] as? NSNumber)?.doubleValue else { return nil }
            if !target.isEmpty, let directory = entry["directory"] as? String, SessionPaths.normalize(directory) != target {
                return nil
            }
            return SessionSnapshot(id: id, modifiedAt: Date(timeIntervalSince1970: updated / 1000))
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func snapshot(cwd: String, executable: String) async -> [SessionSnapshot] {
        guard let output = await CLIOutput.run(executable, ["session", "list", "--format", "json", "--max-count", "50"],
                                               timeout: .seconds(10), directory: cwd) else { return [] }
        return parse(output, cwd: cwd)
    }
}

/// Antigravity CLI's conversations: `~/.gemini/antigravity-cli/cache/conversation_metadata.json`
/// (upstream `snapshot_antigravity_sessions`).
public enum AntigravitySessions {
    public static func metadataFile(homeDirectory: String = NSHomeDirectory()) -> String {
        "\(homeDirectory)/.gemini/antigravity-cli/cache/conversation_metadata.json"
    }

    /// Conversations whose workspace is `cwd`, inside it or around it, newest first.
    public static func parse(_ data: Data, cwd: String, fileDate: Date = .distantPast) -> [(session: SessionSnapshot, preview: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversations = object["conversations"] as? [String: [String: Any]] else { return [] }
        let target = SessionPaths.normalize(cwd)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDates = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            (value as? String).flatMap { dates.date(from: $0) ?? plainDates.date(from: $0) }
        }
        return conversations.compactMap { id, item in
            let summary = item["summary"] as? [String: Any]
            let workspaces = (summary?["WorkspaceURIs"] as? [String] ?? []).map(path(fromURI:))
            guard target.isEmpty || workspaces.contains(where: { related($0, target) }) else { return nil }
            let modified = date(summary?["UpdatedAt"]) ?? date(item["last_modified_time"]) ?? fileDate
            return (SessionSnapshot(id: id, modifiedAt: modified), summary?["Preview"] as? String ?? "")
        }
        .sorted { $0.session.modifiedAt > $1.session.modifiedAt }
    }

    public static func snapshot(cwd: String, homeDirectory: String = NSHomeDirectory()) -> [SessionSnapshot] {
        let file = metadataFile(homeDirectory: homeDirectory)
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? .distantPast
        return parse(data, cwd: cwd, fileDate: fileDate).map(\.session)
    }

    static func path(fromURI uri: String) -> String {
        var clean = uri.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("file://") { clean = String(clean.dropFirst("file://".count)) }
        return SessionPaths.normalize(clean.removingPercentEncoding ?? clean)
    }

    /// Same folder, or one inside the other (a workspace root and a subfolder of it).
    static func related(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

/// Cursor chats are minted by the CLI (`cursor-agent create-chat`), so a pane creates its chat up
/// front and attaches with `--resume <id>` every time (upstream `create_cursor_chat`).
public enum CursorChats {
    /// A chat id as `create-chat` prints it: hex, dashes allowed, 16…64 characters — strict, because
    /// it becomes a spawn argument.
    public static func isChatID(_ value: String) -> Bool {
        (16...64).contains(value.count) && value.first?.isHexDigit == true
            && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The last line of the output that is a chat id.
    public static func chatID(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: isChatID)
    }

    /// Whether `status` reports credentials: `create-chat` waits forever for a login otherwise.
    public static func isSignedIn(statusOutput: String) -> Bool {
        let text = statusOutput.lowercased()
        return !text.contains("not logged in") && !text.contains("not signed in")
    }

    /// A new chat for `cwd`, or nil (not signed in, the CLI failed, or 15 s passed).
    public static func create(executable: String, cwd: String) async -> String? {
        guard let status = await CLIOutput.run(executable, ["status"], timeout: .seconds(10), directory: cwd),
              isSignedIn(statusOutput: status),
              let output = await CLIOutput.run(executable, ["create-chat"], timeout: .seconds(15), directory: cwd) else {
            return nil
        }
        return chatID(in: output)
    }
}
