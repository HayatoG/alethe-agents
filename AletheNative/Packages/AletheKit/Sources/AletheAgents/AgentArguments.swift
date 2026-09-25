import Foundation

/// Session arguments for one launch. Port of upstream `buildAgentLaunch` (`sessionLaunch.ts`):
/// every pane resumes only its own session, so stale resume flags from saved arguments are dropped.
public struct AgentArguments: Equatable, Sendable {
    public var arguments: [String]
    /// The session the process will use, when known before it starts.
    public var sessionID: String?
    /// True when this launch minted `sessionID` (Claude accepts one up front).
    public var createdSession: Bool

    public init(arguments: [String], sessionID: String? = nil, createdSession: Bool = false) {
        self.arguments = arguments
        self.sessionID = sessionID
        self.createdSession = createdSession
    }

    public static func build(
        for kind: AgentKind,
        base: [String] = [],
        sessionID: String? = nil,
        makeSessionID: () -> String = { UUID().uuidString.lowercased() }
    ) -> AgentArguments {
        switch kind {
        case .claude:
            let clean = stripping(base, flagsWithValue: ["--resume", "-r", "--session-id"], flags: ["--continue", "-c"])
            if let sessionID {
                return AgentArguments(arguments: ["--resume", sessionID] + clean, sessionID: sessionID)
            }
            let created = makeSessionID()
            return AgentArguments(arguments: ["--session-id", created] + clean, sessionID: created, createdSession: true)
        case .codex:
            let clean = strippingCodexResume(base)
            return AgentArguments(arguments: sessionID.map { ["resume", $0] + clean } ?? clean, sessionID: sessionID)
        case .opencode:
            let clean = stripping(base, flagsWithValue: ["--session", "-s"], flags: ["--continue", "-c", "--resume"])
            return AgentArguments(arguments: sessionID.map { ["--session", $0] + clean } ?? clean, sessionID: sessionID)
        case .antigravity:
            let clean = stripping(base, flagsWithValue: ["--conversation"], flags: ["--continue", "-c"])
            return AgentArguments(arguments: sessionID.map { ["--conversation", $0] + clean } ?? clean, sessionID: sessionID)
        case .kiro:
            // kiro-cli takes flags such as --trust-all-tools only under `chat`; bare, it rejects them.
            return AgentArguments(arguments: ["chat"] + base)
        case .cursor:
            // Cursor mints its own chat ids; a pane only ever attaches one it already holds.
            let clean = stripping(base, flagsWithValue: ["--resume"], flags: ["--continue"])
                .filter { !$0.hasPrefix("--resume=") }
            return AgentArguments(arguments: sessionID.map { ["--resume", $0] + clean } ?? clean, sessionID: sessionID)
        default:
            return AgentArguments(arguments: base)
        }
    }

    private static func stripping(_ arguments: [String], flagsWithValue: Set<String>, flags: Set<String>) -> [String] {
        var clean: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if flagsWithValue.contains(argument) {
                index += 2
                continue
            }
            if !flags.contains(argument) { clean.append(argument) }
            index += 1
        }
        return clean
    }

    /// `codex resume [--last | <id>] …` → the arguments after the resume target.
    private static func strippingCodexResume(_ arguments: [String]) -> [String] {
        guard arguments.first == "resume" else { return arguments }
        var rest = Array(arguments.dropFirst())
        if let first = rest.first, first == "--last" || !first.hasPrefix("-") { rest.removeFirst() }
        return rest
    }
}
