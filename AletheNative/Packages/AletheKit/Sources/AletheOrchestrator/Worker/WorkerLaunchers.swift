import Foundation
import AletheAgents

extension Launcher {
    /// Codex's JSON-RPC server over stdio (upstream `Launcher::codex_app_server`).
    public static func codexAppServer(program: URL) -> Launcher {
        Launcher(kind: WorkerAgent.codex, program: program, arguments: ["app-server", "--stdio"])
    }

    /// Claude Code's headless stream (upstream `Launcher::claude_headless`). `bypassPermissions`: the
    /// stream has no interactive approval channel, so a tool call needing permission is auto-denied
    /// and reported instead of pausing for an answer.
    public static func claudeHeadless(program: URL) -> Launcher {
        Launcher(kind: WorkerAgent.claude, program: program, arguments: [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
        ])
    }

    /// The arguments for one spawn: Claude keeps its session on disk and only needs the id up front
    /// (Codex resumes over its protocol instead, `thread/resume`).
    public func arguments(resuming session: String?) -> [String] {
        guard kind == WorkerAgent.claude, let session, !session.isEmpty else { return arguments }
        return arguments + ["--resume", session]
    }
}

public enum WorkerLaunchError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No launcher is known for this agent at all.
    case unconfigured(agent: String)
    /// The agent's CLI was looked for and is not installed.
    case cliNotFound(agent: String, command: String)

    /// Upstream's wording for both (it never registers a launcher for a missing CLI), so a job fails
    /// with the same text on both apps.
    public var description: String {
        switch self {
        case .unconfigured(let agent), .cliNotFound(let agent, _): "no worker launcher configured for agent \(agent)"
        }
    }
}

/// The worker launchers, resolved once when the core starts. A missing CLI does not fail the others:
/// only a job for that agent fails, through the core's normal delivery path.
public struct WorkerLaunchers: Sendable {
    public private(set) var launchers: [String: Launcher]
    /// Agents whose CLI was looked for and not found, with the command name.
    public private(set) var missing: [String: String]

    public init(launchers: [String: Launcher] = [:], missing: [String: String] = [:]) {
        self.launchers = launchers
        self.missing = missing
    }

    /// `codex` and `claude` through `resolve` (a `LauncherCache`/`LauncherResolver` lookup honoring
    /// the user's CLI path overrides).
    public static func resolve(_ resolve: (_ command: String) -> String?) -> WorkerLaunchers {
        var result = WorkerLaunchers()
        let known: [(agent: String, make: (URL) -> Launcher)] = [
            (WorkerAgent.codex, Launcher.codexAppServer),
            (WorkerAgent.claude, Launcher.claudeHeadless),
        ]
        for (agent, make) in known {
            if let path = resolve(agent) {
                result.launchers[agent] = make(URL(filePath: path))
            } else {
                result.missing[agent] = agent
            }
        }
        return result
    }

    public func launcher(for agent: String) throws(WorkerLaunchError) -> Launcher {
        if let launcher = launchers[agent] { return launcher }
        if let command = missing[agent] { throw .cliNotFound(agent: agent, command: command) }
        throw .unconfigured(agent: agent)
    }

    /// Replaces or adds one launcher (tests, fake launchers).
    public mutating func set(_ launcher: Launcher) {
        launchers[launcher.kind] = launcher
        missing[launcher.kind] = nil
    }
}

/// The environment a worker starts with: Alethe's own, without what leaks a parent session or an
/// editor into a child (`AgentLauncher.scrubbedVariables`), with the login-shell PATH the launcher
/// resolver builds — the CLI's own directory first, since npm-installed agents start with
/// `#!/usr/bin/env node` and that node lives next to them — then the launcher's additions on top.
/// Values are never logged: they may carry tokens.
public enum WorkerEnvironment {
    public static func make(
        for launcher: Launcher,
        base: [String: String] = ProcessInfo.processInfo.environment,
        searchDirectories: [String]
    ) -> [String: String] {
        var environment = base
        for key in AgentLauncher.scrubbedVariables { environment[key] = nil }
        let own = launcher.program.deletingLastPathComponent().path(percentEncoded: false)
        var path: [String] = []
        for directory in [own] + searchDirectories where !directory.isEmpty {
            let normalized = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            if !path.contains(normalized) { path.append(normalized) }
        }
        environment["PATH"] = path.joined(separator: ":")
        environment.merge(launcher.environment) { _, added in added }
        return environment
    }
}
