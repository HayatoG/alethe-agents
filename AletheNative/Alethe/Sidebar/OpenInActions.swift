import AletheAgents
import AletheGit
import AletheModel
import AppKit

/// Open in VS Code, Reveal in Finder and Open in Browser from the project and terminal menus
/// (P5-7; upstream `open_in_vscode`, `open_in_browser`). Lookups run off the main thread.
@MainActor
enum OpenInActions {
    static func vsCode(_ path: String, launchers: LauncherCache) {
        guard let arguments = VSCodeLauncher.arguments(opening: path) else { return }
        Task {
            let resolution = await Task.detached {
                VSCodeLauncher.resolve(resolver: { launchers.resolve($0) },
                                       appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            }.value
            switch resolution {
            case .cli(let executable):
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                // The `code` script finds its app through PATH-independent paths, but Node-based
                // shims (from a version manager) need the resolver's directories.
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = launchers.searchDirectories.joined(separator: ":")
                process.environment = environment
                do {
                    try process.run()
                } catch {
                    inform(String(localized: "openIn.vscode.failed"), text: error.localizedDescription)
                }
            case .app(let app):
                let configuration = NSWorkspace.OpenConfiguration()
                do {
                    _ = try await NSWorkspace.shared.open([URL(filePath: path, directoryHint: .isDirectory)],
                                                          withApplicationAt: app, configuration: configuration)
                } catch {
                    inform(String(localized: "openIn.vscode.failed"), text: error.localizedDescription)
                }
            case .missing:
                inform(String(localized: "openIn.vscode.missing"), text: String(localized: "openIn.vscode.missing.detail"))
            }
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    /// The project's repository page: the URL it was cloned from, else its `origin` remote.
    static func browser(_ project: Project) {
        let folder = URL(filePath: project.folder, directoryHint: .isDirectory)
        let cloneURL = project.githubURL
        Task {
            let url = await Task.detached { () -> URL? in
                if let url = GitCloneURL.projectWebURL(cloneURL: cloneURL, originRemote: nil) { return url }
                let remote = try? await GitRunner().run(["remote", "get-url", "origin"], in: folder).text
                return GitCloneURL.projectWebURL(cloneURL: nil, originRemote: remote)
            }.value
            guard let url else {
                inform(String(localized: "openIn.browser.none"), text: String(localized: "openIn.browser.none.detail"))
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private static func inform(_ title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
