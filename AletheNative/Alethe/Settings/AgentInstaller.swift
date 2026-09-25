import AletheAgents
import AletheTerminal
import Foundation
import Observation

/// Runs agent installs, updates and uninstalls (upstream `useAgentInstall`): one at a time app-wide
/// (two `npm -g` runs fight over the same folder), in the user's login shell, with a live log, and
/// verified afterwards by looking the CLI up again (and, for an update, by its version moving).
@Observable
@MainActor
final class AgentInstaller {
    enum Status: Equatable { case idle, running, succeeded, failed }

    private(set) var agent: AgentKind?
    private(set) var method: InstallMethod?
    private(set) var status: Status = .idle
    private(set) var log = ""

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var raw = ""

    var isBusy: Bool { status == .running }

    func toolchain(launchers: LauncherCache) async -> InstallToolchain {
        launchers.invalidate()
        let node = launchers.resolve("node")
        return InstallToolchain(node: node == nil ? nil : await CLIVersion.probe(node!),
                                npm: launchers.resolve("npm") != nil, brew: launchers.resolve("brew") != nil)
    }

    func run(_ method: InstallMethod, for agent: AgentKind, cli: String, launchers: LauncherCache) async {
        guard !isBusy else { return }
        self.agent = agent
        self.method = method
        status = .running
        raw = ""
        log = ""
        let command = method.verifyCommand ?? cli
        var before: String?
        if !method.verifyAbsent, let found = launchers.resolve(command) { before = await CLIVersion.probe(found) }

        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = AgentInstallCatalog.shellArguments(for: method)
        #if DEBUG
        // UI tests: print the command instead of running it.
        if UserDefaults.standard.bool(forKey: "AletheInstallDryRun") {
            process.arguments = ["-c", "echo \"dry run: $0\"", method.command]
        }
        #endif
        process.currentDirectoryURL = URL(filePath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        for key in AgentLauncher.scrubbedVariables { environment.removeValue(forKey: key) }
        environment["NONINTERACTIVE"] = "1"  // Homebrew: never wait for a key press
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        self.process = process
        let exit: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        self.process = nil

        launchers.invalidate()
        let found = launchers.resolve(command)
        let worked: Bool
        if method.verifyAbsent {
            worked = found == nil
        } else if let found {
            // An update counts only once the version at that path moves.
            let after = await CLIVersion.probe(found)
            worked = before == nil || (after != nil && after != before)
        } else {
            worked = false
        }
        if exit != 0, !worked { append("\n[exit \(exit)]\n") }
        status = worked ? .succeeded : .failed
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        ProcessTree.kill(process.processIdentifier)
    }

    func reset() {
        guard !isBusy else { return }
        status = .idle
        agent = nil
        method = nil
        log = ""
    }

    private func append(_ text: String) {
        raw += text
        if raw.count > InstallLog.maxCharacters * 2 { raw = String(raw.suffix(InstallLog.maxCharacters)) }
        log = InstallLog.clean(raw)
    }
}
