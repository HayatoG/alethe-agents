import Foundation

/// When a tab's saved conversation is resumed, and how a new one gets bound to its tab.
/// Port of the resume decisions in upstream `useXtermSession.ts`.
public enum SessionResume {
    /// A resumed agent that exits sooner than this is taken to have failed to find its conversation.
    public static let earlyExitWindow: Duration = .seconds(4)

    /// Whether `sessionID` can still be resumed in `cwd`. Claude needs a transcript (an id minted with
    /// `--session-id` only gets one with the first message); Codex needs its rollout for that folder.
    /// Other agents keep their ids in stores we cannot read, so they are trusted.
    public static func isResumable(_ kind: AgentKind, sessionID: String, cwd: String?,
                                   homeDirectory: String = NSHomeDirectory()) -> Bool {
        switch kind {
        case .claude:
            return ClaudeTranscripts.exists(sessionID: sessionID, homeDirectory: homeDirectory)
        case .codex:
            guard let cwd else { return false }
            return CodexSessions.snapshot(cwd: cwd, homeDirectory: homeDirectory).contains { $0.id == sessionID }
        case .antigravity:
            return AntigravitySessions.snapshot(cwd: "", homeDirectory: homeDirectory).contains { $0.id == sessionID }
        default:
            return true
        }
    }

    /// True for agents whose new conversation id is only known once the CLI records it (Cursor
    /// instead creates its chat before the launch).
    public static func discoversNewSessions(_ kind: AgentKind) -> Bool {
        kind == .codex || kind == .opencode || kind == .antigravity
    }

    /// Sessions of an agent in a folder, newest first, for discovery (needs the CLI for OpenCode).
    public static func snapshot(_ kind: AgentKind, cwd: String, executable: String?) async -> [SessionSnapshot] {
        switch kind {
        case .codex: return CodexSessions.snapshot(cwd: cwd)
        case .antigravity: return AntigravitySessions.snapshot(cwd: cwd)
        case .opencode:
            guard let executable else { return [] }
            return await OpenCodeSessions.snapshot(cwd: cwd, executable: executable)
        default: return []
        }
    }

    /// Retry once without the saved conversation when a resumed agent exits right away.
    public static func shouldRetryFresh(resumed: Bool, elapsed: Duration, alreadyRetried: Bool) -> Bool {
        resumed && !alreadyRetried && elapsed < earlyExitWindow
    }

    /// Wait before discovery attempt `attempt` (0-based): every 3 s for the first ten, then every 15 s.
    public static func discoveryDelay(attempt: Int) -> Duration {
        attempt < 10 ? .seconds(3) : .seconds(15)
    }

    /// Polls `attempt` on the discovery schedule until it yields an id or the task is cancelled.
    /// Runs on the caller's actor, so `attempt` can touch its state.
    public static func discover(isolation: isolated (any Actor)? = #isolation,
                                sleep: (Duration) async -> Void,
                                attempt: () async -> String?) async -> String? {
        var index = 0
        while !Task.isCancelled {
            await sleep(discoveryDelay(attempt: index))
            if Task.isCancelled { return nil }
            if let id = await attempt() { return id }
            index += 1
        }
        return nil
    }

    /// The conversation before the current one (upstream `resetLastSession` `pickSessionId`): the
    /// newest session other than `current`, preferring those last written before `before` (when the
    /// current process started); nil when there is none.
    public static func previous(in sessions: [SessionSnapshot], excluding current: String?, before: Date?) -> String? {
        let candidates = sessions.filter { $0.id != current }
        let older = before.map { date in candidates.filter { $0.modifiedAt < date } } ?? []
        return (older.isEmpty ? candidates : older).max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    /// Sessions of an agent for a folder, newest first; empty for agents without readable sessions.
    public static func sessions(_ kind: AgentKind, cwd: String) -> [SessionSnapshot] {
        switch kind {
        case .claude: ClaudeSessions.snapshot(cwd: cwd)
        case .codex: CodexSessions.snapshot(cwd: cwd)
        case .antigravity: AntigravitySessions.snapshot(cwd: cwd)
        default: []
        }
    }
}
