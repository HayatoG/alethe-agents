import Foundation
import Synchronization
import Testing
@testable import AletheAgents

/// Resolver behavior ported from upstream `cli_resolver.rs` tests, on a fake file system.
@Suite struct LauncherResolverTests {
    static func resolver(env: [String: String] = ["PATH": "/usr/bin:/bin"], files: Set<String>,
                         directories: [String: [String]] = [:]) -> LauncherResolver {
        LauncherResolver(environment: env, homeDirectory: "/Users/me",
                         isExecutable: { files.contains($0) }, listDirectory: { directories[$0] ?? [] })
    }

    @Test func findsARealSystemBinaryAndNothingForAMissingOne() {
        let real = LauncherResolver()
        #expect(real.resolve("sh") != nil)
        #expect(real.resolve("non_existent_binary_xyz_123") == nil)
    }

    @Test func pathWinsOverInstallRoots() {
        let resolver = Self.resolver(files: ["/usr/bin/claude", "/Users/me/.local/bin/claude"])
        #expect(resolver.resolve("claude") == "/usr/bin/claude")
    }

    /// An app launched from Finder has no Homebrew or npm prefix on PATH.
    @Test func findsHomebrewAndUserInstallsUnderAMinimalPath() {
        #expect(Self.resolver(files: ["/opt/homebrew/bin/codex"]).resolve("codex") == "/opt/homebrew/bin/codex")
        #expect(Self.resolver(files: ["/Users/me/.npm-global/bin/claude"]).resolve("claude")
            == "/Users/me/.npm-global/bin/claude")
        #expect(Self.resolver(files: ["/Users/me/.claude/local/claude"]).resolve("claude") == "/Users/me/.claude/local/claude")
        #expect(Self.resolver(files: ["/Users/me/.local/share/mise/shims/opencode"]).resolve("opencode")
            == "/Users/me/.local/share/mise/shims/opencode")
    }

    @Test func versionManagersPreferTheNewestNode() {
        let resolver = Self.resolver(
            files: ["/Users/me/.nvm/versions/node/v9.11.2/bin/claude", "/Users/me/.nvm/versions/node/v20.3.0/bin/claude"],
            directories: ["/Users/me/.nvm/versions/node": ["v9.11.2", "v20.3.0", ".DS_Store"]])
        #expect(resolver.resolve("claude") == "/Users/me/.nvm/versions/node/v20.3.0/bin/claude")
    }

    @Test func environmentVariablesRelocateInstallRoots() {
        let env = ["PATH": "/usr/bin", "VOLTA_HOME": "~/tools/volta", "PNPM_HOME": "/pnpm"]
        #expect(Self.resolver(env: env, files: ["/Users/me/tools/volta/bin/codex"]).resolve("codex")
            == "/Users/me/tools/volta/bin/codex")
        #expect(Self.resolver(env: env, files: ["/pnpm/codex"]).resolve("codex") == "/pnpm/codex")
    }

    @Test func aValidOverrideWinsAndABrokenOneFallsBack() {
        let resolver = Self.resolver(files: ["/usr/bin/claude", "/Users/me/bin/claude-dev"])
        #expect(resolver.resolve("claude", override: "~/bin/claude-dev") == "/Users/me/bin/claude-dev")
        #expect(resolver.resolve("claude", override: "/gone/claude") == "/usr/bin/claude")
    }

    @Test func searchDirectoriesAreDeduplicated() {
        let directories = Self.resolver(env: ["PATH": "/opt/homebrew/bin:/usr/bin/::/usr/bin"], files: []).searchDirectories()
        #expect(directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!directories.contains(""))
    }

    @Test func pickedFileMustBeTheAgentsCLI() {
        let cursor = AgentRegistry.builtin.descriptor(for: .cursor)!
        #expect(LauncherResolver.path("/opt/homebrew/bin/cursor-agent", matches: cursor))
        #expect(!LauncherResolver.path("/Applications/Cursor.app/Contents/MacOS/Cursor", matches: cursor))
    }
}

@Suite struct LauncherCacheTests {
    @Test func dropsAHitOnceItsFileIsGone() {
        let files = Mutex<Set<String>>(["/usr/bin/claude"])
        let resolver = LauncherResolver(environment: ["PATH": "/usr/bin"], homeDirectory: "/Users/me",
                                        isExecutable: { path in files.withLock { $0.contains(path) } },
                                        listDirectory: { _ in [] })
        let cache = LauncherCache(resolver: resolver, stillExists: { path in files.withLock { $0.contains(path) } })
        #expect(cache.resolve("claude") == "/usr/bin/claude")
        files.withLock { $0 = ["/opt/homebrew/bin/claude"] }
        #expect(cache.resolve("claude") == "/opt/homebrew/bin/claude")
        files.withLock { $0 = [] }
        #expect(cache.resolve("claude") == nil)
    }
}

@Suite struct AgentLauncherTests {
    static func launcher(files: Set<String>, directories: [String: [String]] = [:],
                         overrides: [String: String] = [:]) -> AgentLauncher {
        let resolver = LauncherResolverTests.resolver(files: files, directories: directories)
        return AgentLauncher(launchers: LauncherCache(resolver: resolver, stillExists: { files.contains($0) }),
                             overrides: overrides)
    }

    @Test func claudeRunsItsResolvedCLIWithASessionAndTheUnrestrictedFlag() throws {
        let command = try Self.launcher(files: ["/Users/me/.nvm/versions/node/v22.1.0/bin/claude"],
                                     directories: ["/Users/me/.nvm/versions/node": ["v22.1.0"]]).command(
            for: AgentLaunchRequest(kind: .claude, workingDirectory: "/src/app", extraArguments: ["--model", "opus"],
                                    unrestricted: true),
            makeSessionID: { "s-1" })
        #expect(command.shellCommand == """
            export PATH='/Users/me/.nvm/versions/node/v22.1.0/bin':"$PATH"; exec \
            '/Users/me/.nvm/versions/node/v22.1.0/bin/claude' '--session-id' 's-1' '--model' 'opus' \
            '--dangerously-skip-permissions'
            """)
        #expect(command.workingDirectory == "/src/app")
        #expect(command.sessionID == "s-1" && command.createdSession)
        #expect(command.environment["CLAUDECODE"] == .some(nil))
        // With it Claude Code stops saving transcripts, and nothing could be resumed.
        #expect(command.environment["CLAUDE_CODE_CHILD_SESSION"] == .some(nil))
    }

    @Test func unrestrictedFlagIsNotRepeated() throws {
        let command = try Self.launcher(files: ["/usr/bin/cursor-agent"]).command(
            for: AgentLaunchRequest(kind: .cursor, extraArguments: ["--force"], unrestricted: true))
        #expect(command.shellCommand?.hasSuffix("exec '/usr/bin/cursor-agent' '--force'") == true)
    }

    @Test func argumentsAreQuotedForTheShell() throws {
        let command = try Self.launcher(files: ["/usr/bin/codex"]).command(
            for: AgentLaunchRequest(kind: .codex, extraArguments: ["-c", "model='o3' $HOME"]))
        #expect(command.shellCommand?.hasSuffix(#"exec '/usr/bin/codex' '-c' 'model='\''o3'\'' $HOME'"#) == true)
    }

    @Test func openCodeGetsItsTerminalWorkaround() throws {
        let command = try Self.launcher(files: ["/usr/bin/opencode"]).command(for: AgentLaunchRequest(kind: .opencode))
        #expect(command.environment["OPENTUI_FORCE_EXPLICIT_WIDTH"] == "false")
    }

    @Test func shellOpensTheLoginShell() throws {
        let command = try Self.launcher(files: []).command(for: AgentLaunchRequest(kind: .shell, workingDirectory: "/tmp"))
        #expect(command.shellCommand == nil)
        #expect(command.workingDirectory == "/tmp")
    }

    @Test func overridesAreHonored() throws {
        let command = try Self.launcher(files: ["/usr/bin/claude", "/custom/claude"], overrides: ["claude": "/custom/claude"])
            .command(for: AgentLaunchRequest(kind: .claude, sessionID: "known"))
        #expect(command.executable == "/custom/claude")
        #expect(command.sessionID == "known" && !command.createdSession)
    }

    @Test func missingOrUnknownAgentsAreReported() {
        #expect(throws: AgentLaunchError.launcherNotFound(command: "cursor-agent")) {
            try Self.launcher(files: []).command(for: AgentLaunchRequest(kind: .cursor))
        }
        #expect(throws: AgentLaunchError.unknownAgent("wsl")) {
            try Self.launcher(files: []).command(for: AgentLaunchRequest(kind: AgentKind(rawValue: "wsl")))
        }
    }
}

/// The generated line runs in a real POSIX shell: quoting survives and the CLI's folder leads PATH.
@Suite struct AgentCommandShellTests {
    @Test func lineRunsInARealShell() throws {
        let registry = AgentRegistry(descriptors: [
            AgentDescriptor(kind: AgentKind(rawValue: "probe"), displayName: "Probe", cliCommand: "sh", unrestrictedFlag: nil),
        ])
        let launcher = AgentLauncher(registry: registry, launchers: LauncherCache(resolver: LauncherResolver()))
        let command = try launcher.command(for: AgentLaunchRequest(
            kind: AgentKind(rawValue: "probe"),
            extraArguments: ["-c", #"printf '%s\n' "$1" "${PATH%%:*}""#, "sh", "it's $HOME \"ok\""]))
        let executable = try #require(command.executable)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", try #require(command.shellCommand)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(process.terminationStatus == 0)
        #expect(lines == [#"it's $HOME "ok""#, (executable as NSString).deletingLastPathComponent])
    }
}
