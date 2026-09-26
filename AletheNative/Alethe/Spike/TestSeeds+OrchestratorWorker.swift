#if DEBUG
import AletheModel
import Foundation

/// `-AletheUITestSeed orchestratorWorker` (P6-15): a board over live stub workers. The Codex CLI
/// override points at `fake-codex` in the data root, a shell script speaking the app-server protocol:
/// a turn whose text contains "ask" stops on a command approval in `/private/tmp` (outside the
/// worker's folder) and, once answered, reports "answered <decision>" plus a diff and keeps its turn
/// running; "hold" keeps the turn running; a steer ends the turn with "steered <text>"; any other
/// turn ends with "did <text>" and a diff.
extension TestSeeds {
    static let orchestratorWorker = "orchestratorWorker"

    private static var dataRoot: URL {
        URL(filePath: UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp")
    }

    static var fakeCodexPath: String { dataRoot.appending(path: "fake-codex").path }

    /// Project `workers` with a disabled Claude Code planner tab `tab-lead` and a board pane, over a
    /// jobs file: job-01 and job-02 interrupted on their threads, job-03 done in a worktree folder.
    static func seedOrchestratorWorker(into doc: inout WorkspaceDocument) {
        let folder = dataRoot.appending(path: "workerrepo")
        let worktree = folder.appending(path: ".alethe/worktrees/job-03")
        let profile = dataRoot.appending(path: "profiles/default")
        for directory in [worktree, profile] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        writeFakeCodex()

        let start: UInt64 = 1_750_000_000_000
        func job(_ id: Int, status: String, extra: [String: Any]) -> [String: Any] {
            [
                "id": String(format: "job-%02d", id), "plannerId": "tab-lead", "agent": "codex", "runId": "run-01",
                "runLabel": "Stub workers", "spec": "Task \(id)", "cwd": folder.path, "status": status,
                "plan": [String](), "summary": "", "approvalPolicy": "\"never\"", "sandbox": "workspace-write",
                "webSearch": false, "startedAt": start, "endedAt": start + UInt64(30_000 + id * 1000),
            ].merging(extra) { _, new in new }
        }
        let file: [String: Any] = [
            "version": 2,
            "jobs": [
                job(1, status: "interrupted", extra: ["threadId": "thread-one"]),
                job(2, status: "interrupted", extra: ["threadId": "thread-two"]),
                job(3, status: "done", extra: ["threadId": "thread-three", "summary": "Docs updated.",
                                               "worktree": worktree.path]),
            ],
            "planners": [["id": "tab-lead", "label": "lead", "agent": "claude"]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: file) {
            try? data.write(to: profile.appending(path: "orchestrator-jobs.json"))
        }

        let project = doc.addProject(name: "workers", folder: folder.path, color: .purple)
        if let pane = doc.addPane(to: project, tab: PaneTab(id: TabID(rawValue: "tab-lead"), agent: "claude", title: "lead")) {
            doc.setDisabled(pane, true)
        }
        doc.addPane(to: project, content: .orchestrator)
        doc.workspace.selectedProjectID = project
    }

    static func seedOrchestratorWorker(into preferences: inout PreferencesDocument) {
        preferences.features.set(.orchestrator, on: true)
        var paths = preferences.cliPaths ?? [:]
        paths["codex"] = fakeCodexPath
        preferences.cliPaths = paths
    }

    private static func writeFakeCodex() {
        let script = #"""
        #!/bin/sh
        # A stub `codex app-server` for the P6-15 UI tests. printf '%s' keeps the diff's JSON escapes.
        n=0
        diff='{"method":"turn/diff/updated","params":{"diff":"diff --git a/notes.txt b/notes.txt\n--- a/notes.txt\n+++ b/notes.txt\n@@ -1,2 +1,2 @@\n alpha\n-beta\n+beta two\n"}}'
        while IFS= read -r line; do
          text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
          case "$line" in
            *'"method":"thread/start"'*|*'"method":"thread/resume"'*)
              printf '{"id":2,"result":{"thread":{"id":"thread-stub"}}}\n' ;;
            *'"method":"turn/steer"'*)
              printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"steered %s"}}}\n' "$text"
              printf '{"method":"turn/completed","params":{}}\n' ;;
            *'"method":"turn/start"'*)
              n=$((n+1))
              printf '{"method":"turn/started","params":{"turn":{"id":"turn-%s"}}}\n' "$n"
              case "$text" in
                *ask*)
                  printf '{"id":77,"method":"item/commandExecution/requestApproval","params":{"command":"touch notes.txt","cwd":"/private/tmp","reason":"needs a scratch file"}}\n' ;;
                *hold*)
                  printf '{"method":"item/agentMessage/delta","params":{"delta":"holding"}}\n' ;;
                *)
                  printf '%s\n' "$diff"
                  printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"did %s"}}}\n' "$text"
                  printf '{"method":"turn/completed","params":{}}\n' ;;
              esac ;;
            *'"id":77'*)
              decision=$(printf '%s' "$line" | sed -n 's/.*"decision":"\([^"]*\)".*/\1/p')
              printf '%s\n' "$diff"
              printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"answered %s"}}}\n' "$decision" ;;
          esac
        done
        """#
        let url = URL(filePath: fakeCodexPath)
        try? Data(script.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
#endif
