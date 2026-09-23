import AletheAgents
import AletheTerminal

extension AgentCommand {
    /// The PTY launch for this command: the user's login shell, running the agent line if any.
    func ptyLaunch(size: PTYSize) -> PTYLaunch {
        ShellLaunch.loginShell(command: shellCommand, workingDirectory: workingDirectory, size: size,
                               environmentChanges: environment)
    }
}
