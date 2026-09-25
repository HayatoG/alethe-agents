import Foundation
import Testing
@testable import AletheOrchestrator

struct WorkerLaunchersTests {
    @Test func codexRunsTheAppServerOverStdio() {
        let launcher = Launcher.codexAppServer(program: URL(filePath: "/opt/homebrew/bin/codex"))
        #expect(launcher.kind == "codex")
        #expect(launcher.arguments == ["app-server", "--stdio"])
        #expect(launcher.environment.isEmpty)
        #expect(launcher.arguments(resuming: "thread-1") == ["app-server", "--stdio"], "Codex resumes over its protocol")
    }

    @Test func claudeRunsHeadlessWithStreamJSON() {
        let launcher = Launcher.claudeHeadless(program: URL(filePath: "/Users/me/.local/bin/claude"))
        #expect(launcher.kind == "claude")
        #expect(launcher.arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions",
        ])
        #expect(launcher.arguments(resuming: "abc") == launcher.arguments + ["--resume", "abc"])
        #expect(launcher.arguments(resuming: nil) == launcher.arguments)
        #expect(launcher.arguments(resuming: "") == launcher.arguments)
    }

    @Test func aMissingCLIFailsOnlyItsOwnAgent() throws {
        let launchers = WorkerLaunchers.resolve { $0 == "codex" ? "/usr/local/bin/codex" : nil }
        #expect(try launchers.launcher(for: "codex").program.path == "/usr/local/bin/codex")
        #expect(throws: WorkerLaunchError.cliNotFound(agent: "claude", command: "claude")) {
            try launchers.launcher(for: "claude")
        }
        #expect(throws: WorkerLaunchError.unconfigured(agent: "gemini")) { try launchers.launcher(for: "gemini") }
        #expect(WorkerLaunchError.cliNotFound(agent: "claude", command: "claude").description
            == "no worker launcher configured for agent claude")
    }

    @Test func settingALauncherClearsItsMissingMark() throws {
        var launchers = WorkerLaunchers.resolve { _ in nil }
        launchers.set(Launcher(kind: "claude", program: URL(filePath: "/tmp/fake-claude"), arguments: []))
        #expect(try launchers.launcher(for: "claude").program.path == "/tmp/fake-claude")
        #expect(launchers.missing["claude"] == nil)
    }

    @Test func theEnvironmentIsScrubbedAndCarriesTheLoginPath() {
        let launcher = Launcher(kind: "claude", program: URL(filePath: "/Users/me/.nvm/versions/node/v22/bin/claude"),
                                arguments: [], environment: ["EXTRA": "1", "HOME": "/override"])
        let environment = WorkerEnvironment.make(
            for: launcher,
            base: ["HOME": "/Users/me", "PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
                   "VSCODE_IPC_HOOK": "x", "LANG": "en_US.UTF-8"],
            searchDirectories: ["/usr/bin", "/bin", "/opt/homebrew/bin/", "/Users/me/.nvm/versions/node/v22/bin"])
        #expect(environment["PATH"] == "/Users/me/.nvm/versions/node/v22/bin:/usr/bin:/bin:/opt/homebrew/bin")
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(environment["VSCODE_IPC_HOOK"] == nil)
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["EXTRA"] == "1")
        #expect(environment["HOME"] == "/override", "the launcher's additions win")
    }
}
