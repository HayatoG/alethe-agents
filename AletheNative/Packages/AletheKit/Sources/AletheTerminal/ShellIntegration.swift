import Foundation
import GhosttyTerminal

/// Shell integration for interactive shells (port of libghostty's `termio/shell_integration.zig`,
/// which host-managed mode never runs): zsh and bash load the integration bundled with GhosttyKit,
/// which emits OSC 133 prompt marks (prompt redraw on resize, jump to prompt) and OSC 7 (the working
/// directory). No user file is touched: zsh gets a `ZDOTDIR` that restores the user's own and
/// sources their startup files; bash starts in POSIX mode with `ENV` pointing at the script, which
/// leaves POSIX mode and replays the startup files bash would have read.
///
/// Not covered: fish (GhosttyKit bundles no fish integration), macOS's `/bin/bash` 3.2 (skipped by
/// Ghostty too), and `-c` commands (agents), which are not interactive.
public enum ShellIntegration {
    public enum Shell: Equatable, Sendable {
        case zsh, bash
    }

    /// Features the scripts read (`cursor`: bar cursor while editing; `title`: OSC 2 title).
    public static let features = "cursor,title"

    public static func detect(executable: String) -> Shell? {
        switch (executable as NSString).lastPathComponent {
        case "zsh": .zsh
        case "bash" where executable != "/bin/bash": .bash
        default: nil
        }
    }

    /// `launch` with the integration injected, or unchanged when its shell is not supported, it runs
    /// a command, or the resources are missing.
    public static func apply(to launch: PTYLaunch,
                             resources: URL? = GhosttyRuntimeResources.directoryURL,
                             home: String = NSHomeDirectory(),
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PTYLaunch {
        guard let resources, let shell = detect(executable: launch.executable),
              !launch.arguments.dropFirst().contains(where: isCommandFlag) else { return launch }
        let root = resources.appending(path: "shell-integration").path
        var result = launch
        switch shell {
        case .zsh:
            let directory = root + "/zsh"
            guard fileExists(directory + "/.zshenv") else { return launch }
            if let old = launch.environment["ZDOTDIR"] { result.environment["GHOSTTY_ZSH_ZDOTDIR"] = old }
            result.environment["ZDOTDIR"] = directory
        case .bash:
            let script = root + "/bash/ghostty.bash"
            guard fileExists(script), let bash = bashArguments(launch.arguments) else { return launch }
            result.arguments = bash.arguments
            if let old = launch.environment["ENV"] { result.environment["GHOSTTY_BASH_ENV"] = old }
            result.environment["ENV"] = script
            result.environment["GHOSTTY_BASH_INJECT"] = bash.inject
            if let rcfile = bash.rcfile { result.environment["GHOSTTY_BASH_RCFILE"] = rcfile }
            // POSIX mode would default the history to ~/.sh_history.
            if launch.environment["HISTFILE"] == nil {
                result.environment["HISTFILE"] = home + "/.bash_history"
                result.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
        }
        result.environment["GHOSTTY_SHELL_FEATURES"] = features
        return result
    }

    /// A single-dash option that includes `c` (`-c`, `-lc`, `-ic`…): the shell runs a command.
    private static func isCommandFlag(_ argument: String) -> Bool {
        argument.count > 1 && argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.contains("c")
    }

    /// Bash's argv rewritten for injection: `--posix` added, `--norc` / `--noprofile` / `--rcfile`
    /// moved into the environment (the script honors them). Nil when bash must run as given.
    static func bashArguments(_ arguments: [String]) -> (arguments: [String], inject: String, rcfile: String?)? {
        guard let executable = arguments.first else { return nil }
        var result = [executable, "--posix"]
        var inject = "1"
        var rcfile: String?
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--posix":
                return nil
            case "--norc", "--noprofile":
                inject += " " + argument
            case "--rcfile", "--init-file":
                rcfile = rest.popFirst()
            case "-", "--":
                result.append(argument)
                result.append(contentsOf: rest)
                rest = []
            default:
                if isCommandFlag(argument) { return nil }
                result.append(argument)
            }
        }
        return (result, inject, rcfile)
    }
}
