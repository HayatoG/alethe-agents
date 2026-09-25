import Foundation

/// What version an agent CLI reports (upstream `agent_cli_version`, `cli_version_at`).
public enum CLIVersion {
    /// Tried in order: the CLIs disagree, and none documents it (upstream `VERSION_FLAGS`).
    public static let flags = ["--version", "-v", "version"]

    /// The first dotted number in the output, trailing dot dropped (upstream `parse_version`).
    public static func parse(_ output: String) -> String? {
        output.split { !($0.isNumber || $0 == ".") }
            .first { $0.contains(".") && $0.first?.isNumber == true }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }

    /// Runs the CLI with each flag until one prints a version; nil when none does or it hangs past
    /// `timeout`. The CLI's own directory leads PATH (npm CLIs start with `#!/usr/bin/env node`).
    public static func probe(_ executable: String, timeout: Duration = .seconds(5)) async -> String? {
        for flag in flags {
            if let version = await run(executable, flag, timeout: timeout).flatMap(parse) { return version }
        }
        return nil
    }

    private static func run(_ executable: String, _ flag: String, timeout: Duration) async -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = [flag]
        var environment = ProcessInfo.processInfo.environment
        let directory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = directory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let reader = Task.detached { String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let text = await reader.value
        watchdog.cancel()
        return text
    }
}
