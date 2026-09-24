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
        default:
            return true
        }
    }

    /// True for agents whose new conversation id is only known once the CLI writes it to disk.
    public static func discoversNewSessions(_ kind: AgentKind) -> Bool { kind == .codex }

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
}
