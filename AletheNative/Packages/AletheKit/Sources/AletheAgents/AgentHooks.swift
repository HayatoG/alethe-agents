import Foundation

/// What an agent tab is doing (upstream sidebar status: working / waiting, plus completion).
public enum AgentActivity: String, Hashable, Sendable {
    /// Started, nothing asked yet.
    case idle
    /// Working on a prompt.
    case working
    /// Stopped to ask the user something (a permission, a question).
    case needsInput
    /// Finished its turn; waiting for the next prompt.
    case done
}

/// One event an agent reported through the hook bridge.
public struct AgentHookEvent: Equatable, Sendable {
    public var activity: AgentActivity?
    /// The conversation the pane is on now (Claude `SessionStart` / `UserPromptSubmit`): after
    /// `/clear` or an in-CLI `/resume` it is no longer the id the pane was launched with.
    public var sessionID: String?
    /// Short text for a notification (Claude's `Notification` message).
    public var message: String?

    public init(activity: AgentActivity? = nil, sessionID: String? = nil, message: String? = nil) {
        self.activity = activity
        self.sessionID = sessionID
        self.message = message
    }

    /// A Claude Code hook body (upstream `claudeSessionFromHook` for the session; the rest maps the
    /// lifecycle events to activity).
    public static func claude(_ body: Data) -> AgentHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = object["hook_event_name"] as? String else { return nil }
        let session = (object["session_id"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        switch name {
        case "SessionStart": return AgentHookEvent(activity: .idle, sessionID: session)
        case "UserPromptSubmit": return AgentHookEvent(activity: .working, sessionID: session)
        case "Stop": return AgentHookEvent(activity: .done)
        case "Notification":
            let message = object["message"] as? String
            // Claude also notifies after 60 s idle at the prompt; that is not a question.
            let idle = message?.lowercased().contains("waiting for your input") == true
            return AgentHookEvent(activity: idle ? .done : .needsInput, message: message)
        default: return nil
        }
    }

    /// A Codex `notify` payload: `agent-turn-complete` ends a turn.
    public static func codex(_ body: Data) -> AgentHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["type"] as? String == "agent-turn-complete" else { return nil }
        let message = object["last-assistant-message"] as? String
        return AgentHookEvent(activity: .done, message: message)
    }
}

/// Wiring a launch into the bridge without touching the user's own configuration.
public enum AgentHookWiring {
    public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "Notification"]

    /// Claude Code settings layered on top of the user's with `--settings` (upstream
    /// `agent_hooks_settings_path`): each event posts to the bridge with the tab id and the token.
    public static func claudeSettings(endpoint: String, token: String, tab: String) -> Data {
        let hook: [[String: Any]] = [["hooks": [[
            "type": "http", "url": "\(endpoint)/hook/claude", "timeout": 5,
            "headers": ["X-Alethe-Token": token, "X-Alethe-Tab": tab],
        ]]]]
        let settings: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, hook) })]
        return (try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Codex runs `notify` with the event JSON as its last argument; this script forwards it.
    public static func codexForwarder(endpoint: String, token: String) -> String {
        """
        #!/bin/sh
        # Alethe: forwards a Codex notification to the app (tab id, then the event JSON).
        exec /usr/bin/curl -s -m 5 -o /dev/null -X POST \\
          -H "X-Alethe-Token: \(token)" -H "X-Alethe-Tab: $1" -H "Content-Type: application/json" \\
          --data-binary "$2" "\(endpoint)/hook/codex"
        """
    }

    /// `-c notify=[…]` for one launch: Codex appends the JSON to these arguments.
    public static func codexArguments(script: String, tab: String) -> [String] {
        func toml(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return ["-c", "notify=[\(["/bin/sh", script, tab].map(toml).joined(separator: ","))]"]
    }
}

/// Infers working / done from a terminal's traffic for agents without hooks (upstream
/// `AgentCompletionMonitor`): a submitted prompt arms it, real output (not the echo) makes it
/// working, and 4.5 s of quiet ends the turn. Times are seconds on any clock.
public struct ActivityMonitor: Sendable {
    public static let responseIdle: TimeInterval = 4.5
    static let minimumResponse: TimeInterval = 0.7
    static let echoGrace: TimeInterval = 0.35
    static let minimumOutput = 12

    private enum State: Sendable { case idle, armed, working }
    private var state = State.idle
    private var line = ""
    private var prompt = ""
    private var submittedAt: TimeInterval = 0
    private var outputCharacters = 0
    /// When the turn ends if nothing more is printed; nil while no turn is running.
    public private(set) var deadline: TimeInterval?

    public init() {}

    /// Keyboard input; returns `.working` when a prompt was submitted.
    public mutating func input(_ text: String, at now: TimeInterval) -> AgentActivity? {
        var result: AgentActivity?
        for character in text {
            switch character {
            case "\r", "\n":
                let submitted = line.trimmingCharacters(in: .whitespaces)
                line = ""
                if !submitted.isEmpty {
                    state = .armed
                    prompt = submitted
                    submittedAt = now
                    outputCharacters = 0
                    deadline = nil
                    result = .working
                }
            case "\u{8}", "\u{7F}":
                if !line.isEmpty { line.removeLast() }
            default:
                if character.asciiValue.map({ $0 >= 0x20 }) ?? true { line.append(character) }
            }
        }
        return result
    }

    /// Output (escape sequences already stripped or not; they are removed here).
    public mutating func output(_ text: String, at now: TimeInterval) {
        guard state != .idle else { return }
        let visible = Self.stripControls(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return }
        if now - submittedAt <= Self.echoGrace, !prompt.isEmpty, visible.contains(prompt) { return }
        outputCharacters += visible.count
        if state == .armed, outputCharacters >= Self.minimumOutput { state = .working }
        if state == .working { deadline = now + Self.responseIdle }
    }

    /// `.done` once the deadline passed after a real response.
    public mutating func tick(at now: TimeInterval) -> AgentActivity? {
        guard state == .working, let deadline, now >= deadline, now - submittedAt >= Self.minimumResponse else { return nil }
        state = .idle
        self.deadline = nil
        return .done
    }

    static func stripControls(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-?]*[ -/]*[@-~]|\u{1B}\][^\u{07}]*(?:\u{07}|\u{1B}\\)|\u{1B}[PX^_].*?\u{1B}\\|\u{1B}[@-_]"#,
                                  with: "", options: .regularExpression)
    }
}
