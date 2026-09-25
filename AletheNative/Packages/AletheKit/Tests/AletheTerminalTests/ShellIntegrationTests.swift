import Darwin
import Foundation
import Testing
@testable import AletheTerminal

// Spawns real processes: a rare intermittent hang must fail the test, not stall the run.
@Suite(.timeLimit(.minutes(1))) struct ShellIntegrationTests {
    private let resources = URL(filePath: "/res")
    private func launch(_ executable: String, _ arguments: [String], env: [String: String] = [:]) -> PTYLaunch {
        PTYLaunch(executable: executable, arguments: arguments, environment: env, workingDirectory: nil,
                  size: PTYSize(columns: 80, rows: 24))
    }
    private func apply(_ launch: PTYLaunch) -> PTYLaunch {
        ShellIntegration.apply(to: launch, resources: resources, home: "/Users/me", fileExists: { _ in true })
    }

    @Test func zshGetsTheIntegrationZdotdirAndKeepsTheUsersOne() {
        let plain = apply(launch("/bin/zsh", ["-zsh"]))
        #expect(plain.environment["ZDOTDIR"] == "/res/shell-integration/zsh")
        #expect(plain.environment["GHOSTTY_ZSH_ZDOTDIR"] == nil)
        #expect(plain.environment["GHOSTTY_SHELL_FEATURES"] == ShellIntegration.features)
        #expect(plain.arguments == ["-zsh"])

        let custom = apply(launch("/bin/zsh", ["-zsh"], env: ["ZDOTDIR": "/Users/me/.config/zsh"]))
        #expect(custom.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/Users/me/.config/zsh")
    }

    @Test func bashStartsInPosixModeWithTheScriptAsEnv() {
        let result = apply(launch("/opt/homebrew/bin/bash", ["-bash"], env: ["ENV": "/Users/me/.envrc"]))
        #expect(result.arguments == ["-bash", "--posix"])
        #expect(result.environment["ENV"] == "/res/shell-integration/bash/ghostty.bash")
        #expect(result.environment["GHOSTTY_BASH_ENV"] == "/Users/me/.envrc")
        #expect(result.environment["GHOSTTY_BASH_INJECT"] == "1")
        #expect(result.environment["HISTFILE"] == "/Users/me/.bash_history")
        #expect(result.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")
    }

    @Test func bashOptionsMoveIntoTheEnvironment() {
        let parsed = ShellIntegration.bashArguments(["bash", "--norc", "--rcfile", "x.sh", "-l", "--", "a"])
        #expect(parsed?.arguments == ["bash", "--posix", "-l", "--", "a"])
        #expect(parsed?.inject == "1 --norc")
        #expect(parsed?.rcfile == "x.sh")
        #expect(ShellIntegration.bashArguments(["bash", "--posix"]) == nil)
    }

    @Test func leavesCommandsUnsupportedShellsAndMissingFilesAlone() {
        for untouched in [
            launch("/bin/zsh", ["-zsh", "-c", "claude"]),
            launch("/opt/homebrew/bin/bash", ["bash", "-lc", "ls"]),
            launch("/bin/bash", ["-bash"]),
            launch("/opt/homebrew/bin/fish", ["-fish"]),
        ] {
            #expect(apply(untouched).environment == untouched.environment)
            #expect(apply(untouched).arguments == untouched.arguments)
        }
        let missing = ShellIntegration.apply(to: launch("/bin/zsh", ["-zsh"]), resources: resources,
                                             fileExists: { _ in false })
        #expect(missing.environment["ZDOTDIR"] == nil)
        #expect(ShellIntegration.apply(to: launch("/bin/zsh", ["-zsh"]), resources: nil).environment.isEmpty)
    }

    /// The bundled zsh integration really marks prompts: an interactive zsh started as the app does
    /// prints OSC 133 A before its first prompt and D after a command.
    @Test func interactiveZshEmitsPromptMarks() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "alethe-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let base = launch("/bin/zsh", ["-zsh"], env: ["PATH": "/usr/bin:/bin", "HOME": home.path, "TERM": "xterm-256color"])
        let launch = ShellIntegration.apply(to: base, home: home.path)
        #expect(launch.environment["ZDOTDIR"] != nil, "GhosttyKit must bundle the zsh integration")

        let process = try PTYProcess(launch)
        let collected = Collected()
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.onOutput = { collected.append($0) }
            process.onExit = { continuation.resume(returning: $0) }
            process.start()
            process.write(Data("true\nexit\n".utf8))
        }
        #expect(code == 0)
        #expect(collected.string.contains("\u{1b}]133;A"))
        #expect(collected.string.contains("\u{1b}]133;D;0"))
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
