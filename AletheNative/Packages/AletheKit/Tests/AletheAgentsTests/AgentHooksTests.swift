import Foundation
import Synchronization
import Testing
@testable import AletheAgents

/// Hook bridge (P3-9).
@Suite struct AgentHooksTests {
    @Test func claudeEventsMapToActivityAndSession() {
        func event(_ json: String) -> AgentHookEvent? { AgentHookEvent.claude(Data(json.utf8)) }
        #expect(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"s2"}"#) == AgentHookEvent(activity: .working, sessionID: "s2"))
        #expect(event(#"{"hook_event_name":"Stop","session_id":"s2"}"#)?.activity == .done)
        #expect(event(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#)?.activity == .needsInput)
        #expect(event(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#)?.activity == .done)
        #expect(event(#"{"hook_event_name":"SessionStart","session_id":" "}"#)?.sessionID == nil)
        #expect(event(#"{"hook_event_name":"PreToolUse"}"#) == nil)
        #expect(AgentHookEvent.codex(Data(#"{"type":"agent-turn-complete","last-assistant-message":"Done."}"#.utf8))
                == AgentHookEvent(activity: .done, message: "Done."))
    }

    @Test func claudeSettingsCarryTheTokenAndTab() throws {
        let data = AgentHookWiring.claudeSettings(endpoint: "http://127.0.0.1:5000", token: "tok", tab: "t1")
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentHookWiring.events))
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop.first?["url"] as? String == "http://127.0.0.1:5000/hook/claude")
        #expect((stop.first?["headers"] as? [String: String]) == ["X-Alethe-Token": "tok", "X-Alethe-Tab": "t1"])
    }

    /// P6-11: a planner's settings add the subagent events and in-process teammates; without the
    /// orchestrator feature they stay as P3-9 wrote them.
    @Test func plannerSettingsAddTheSubagentEvents() throws {
        func settings(_ orchestrator: Bool) throws -> [String: Any] {
            let data = AgentHookWiring.claudeSettings(endpoint: "http://127.0.0.1:5000", token: "tok", tab: "t1", orchestrator: orchestrator)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let plain = try settings(false)
        #expect(Set(try #require(plain["hooks"] as? [String: Any]).keys) == Set(AgentHookWiring.events))
        #expect(plain["teammateMode"] == nil)
        let planner = try settings(true)
        let hooks = try #require(planner["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentHookWiring.events + ["SubagentStart", "SubagentStop", "PreToolUse", "PostToolUse",
                                                                 "TeammateIdle", "TaskCreated", "TaskCompleted"]))
        #expect(planner["teammateMode"] as? String == "in-process")
        let start = try #require((hooks["SubagentStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect((start.first?["headers"] as? [String: String]) == ["X-Alethe-Token": "tok", "X-Alethe-Tab": "t1"])
    }

    @Test func subagentHooksParseTheirFields() throws {
        let body = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"npm run dev","description":"","run_in_background":true,"timeout":5},"tool_response":{"backgroundTaskId":"sh1"},"agent_transcript_path":"/t/a.jsonl"}"#
        let hook = try #require(SubagentHook.parse(Data(body.utf8)))
        #expect(hook == SubagentHook(event: "PostToolUse", toolName: "Bash", input: ["command": "npm run dev"],
                                     runInBackground: true, response: ["backgroundTaskId": "sh1"], transcriptPath: "/t/a.jsonl"))
        #expect(SubagentHook.parse(Data(#"{"hook_event_name":"SubagentStart","agent_id":"","agent_type":"Explore"}"#.utf8))
                == SubagentHook(event: "SubagentStart", agentType: "Explore"))
        #expect(SubagentHook.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil, "lifecycle events stay P3-9's")
        #expect(SubagentHook.parse(Data(#"{"hook_event_name":"TaskCreated","task_id":"1"}"#.utf8)) == nil)
        #expect(SubagentHook.parse(Data("not json".utf8)) == nil)
    }

    @Test func codexSubagentHooksAreOneLaunchOverride() {
        let arguments = AgentHookWiring.codexSubagentArguments(script: "/tmp/it's.sh", tab: "t1")
        #expect(arguments == [
            "-c", #"hooks.SubagentStart=[{matcher=".*",hooks=[{type="command",command="/bin/sh '/tmp/it'\''s.sh' 't1'",timeout=5}]}]"#,
            "-c", #"hooks.SubagentStop=[{matcher=".*",hooks=[{type="command",command="/bin/sh '/tmp/it'\''s.sh' 't1'",timeout=5}]}]"#,
        ])
        let script = AgentHookWiring.codexHookForwarder(endpoint: "http://127.0.0.1:5000", token: "tok")
        #expect(script.contains("--data-binary @- \"http://127.0.0.1:5000/hook/codex-subagents\""))
    }

    @Test func codexNotifyIsATomlArray() {
        #expect(AgentHookWiring.codexArguments(script: "/tmp/a b.sh", tab: "t\"1")
                == ["-c", #"notify=["/bin/sh","/tmp/a b.sh","t\"1"]"#])
    }

    @Test func launchesCarryTheWiring() throws {
        let launcher = AgentLauncher(launchers: LauncherCache(stillExists: { _ in true }), overrides: ["claude": "/bin/echo", "codex": "/bin/echo"])
        let claude = try launcher.command(for: AgentLaunchRequest(kind: .claude, sessionID: "s1",
                                                                  hooks: .init(claudeSettingsPath: "/tmp/h.json")))
        #expect(claude.shellCommand?.contains("'--resume' 's1' '--settings' '/tmp/h.json'") == true)
        let codex = try launcher.command(for: AgentLaunchRequest(kind: .codex, sessionID: "c1",
                                                                 hooks: .init(codexArguments: ["-c", "notify=[]"])))
        #expect(codex.shellCommand?.contains("'-c' 'notify=[]' 'resume' 'c1'") == true)
    }

    @Test func monitorArmsOnSubmitAndEndsAfterQuiet() {
        var monitor = ActivityMonitor()
        #expect(monitor.input("fix it", at: 0) == nil)
        #expect(monitor.input("\r", at: 0) == .working)
        monitor.output("fix it", at: 0.1)            // the echo
        #expect(monitor.deadline == nil)
        monitor.output("\u{1B}[32mWorking on the fix now…\u{1B}[0m", at: 1)
        #expect(monitor.deadline == 1 + ActivityMonitor.responseIdle)
        #expect(monitor.tick(at: 3) == nil)
        #expect(monitor.tick(at: 6) == .done)
        #expect(monitor.tick(at: 20) == nil, "once")
    }

    @Test func requestsParseAndWaitForTheirBody() {
        let raw = "POST /hook/claude HTTP/1.1\r\nX-Alethe-Token: t\r\nContent-Length: 5\r\n\r\nhel"
        #expect(HTTPRequest.parse(Data(raw.utf8), bodyLimit: 10) == .incomplete)
        guard case .request(let request) = HTTPRequest.parse(Data((raw + "lo").utf8), bodyLimit: 10) else {
            Issue.record("not parsed"); return
        }
        #expect(request.path == "/hook/claude" && request.headers["x-alethe-token"] == "t" && request.body == Data("hello".utf8))
        #expect(HTTPRequest.parse(Data((raw + "lo").utf8), bodyLimit: 4) == .tooLarge)
    }

    /// P: a real request reaches the handler over loopback; a wrong token does not.
    @Test func serverRoundTrip() async throws {
        let received = Mutex<[String]>([])
        let server = AgentHookServer(token: "secret") { agent, tab, body in
            received.withLock { $0.append("\(agent)|\(tab)|\(String(decoding: body, as: UTF8.self))") }
        }
        let endpoint = try #require(await server.start())
        defer { server.stop() }
        func post(token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "\(endpoint)/hook/claude")!)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-Alethe-Token")
            request.setValue("tab1", forHTTPHeaderField: "X-Alethe-Tab")
            request.httpBody = Data(#"{"hook_event_name":"Stop"}"#.utf8)
            return (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
        }
        #expect(try await post(token: "secret") == 200)
        #expect(try await post(token: "wrong") == 401)
        #expect(received.withLock { $0 } == [#"claude|tab1|{"hook_event_name":"Stop"}"#])
    }
}

struct ActivityMonitorControlsTests {
    @Test func stripsEscapeSequences() {
        #expect(ActivityMonitor.stripControls("\u{1B}[1;32mdone\u{1B}[0m \u{1B}]0;title\u{07}ok") == "done ok")
    }
}
