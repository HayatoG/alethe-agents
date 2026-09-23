import Foundation

/// Claude Code keeps one transcript per session at `~/.claude/projects/<encoded cwd>/<id>.jsonl`.
/// A session id minted with `--session-id` only gets a transcript once the conversation starts, so
/// resuming an id without one fails ("No conversation found").
public enum ClaudeTranscripts {
    public static func exists(sessionID: String, homeDirectory: String = NSHomeDirectory(),
                              fileManager: FileManager = .default) -> Bool {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return false }
        let projects = "\(homeDirectory)/.claude/projects"
        let folders = (try? fileManager.contentsOfDirectory(atPath: projects)) ?? []
        return folders.contains { fileManager.fileExists(atPath: "\(projects)/\($0)/\(sessionID).jsonl") }
    }
}
