#if DEBUG
import AletheModel
import AppKit
import Foundation

/// Sample workspaces for UI tests (`-AletheUITestSeed <name>`); applied only to an empty workspace.
enum TestSeeds {
    static func apply(_ name: String, to doc: inout WorkspaceDocument) {
        switch name {
        case "sidebar":
            let work = doc.addGroup(name: "Work", color: .purple)
            let clients = doc.addGroup(name: "Clients", parent: work)
            doc.addProject(name: "alpha", folder: "/private/tmp", color: .orange, in: .group(work))
            doc.addProject(name: "beta", folder: "/private/tmp", color: .blue, in: .group(work))
            doc.addProject(name: "client-site", folder: "/private/tmp", color: .teal, in: .group(clients))
            doc.addProject(name: "scratch", folder: "/private/tmp", color: .pink)
        case "terminals":
            let project = doc.addProject(name: "scratch", folder: "/private/tmp", color: .pink)
            doc.addPane(to: project, tab: PaneTab(agent: "claude"))
        case "panes":
            let api = doc.addProject(name: "api", folder: "/private/tmp", color: .orange)
            let web = doc.addProject(name: "web", folder: "/private/tmp", color: .teal)
            for title in ["one", "two", "three"] { doc.addPane(to: api, tab: PaneTab(agent: "shell", title: title)) }
            doc.addPane(to: web, tab: PaneTab(agent: "shell", title: "four"))
        case "subtabs":
            let project = doc.addProject(name: "scratch", folder: "/private/tmp", color: .pink)
            let pane = doc.addPane(to: project, tab: PaneTab(agent: "shell", title: "one"))
            if let pane { doc.addTab(PaneTab(agent: "shell", title: "two"), to: pane) }
        case "markdown":
            // A README inside the throwaway data root, so the test never touches real files.
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let file = URL(filePath: root).appending(path: "README.md")
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try? Data("# Seeded\n\n- [x] done\n\n| a | b |\n|---|---|\n| 1 | 2 |\n".utf8).write(to: file)
            let project = doc.addProject(name: "docs", folder: root, color: .teal)
            doc.addPane(to: project, content: .markdown(path: file.path))
        case "media":
            // A 64×64 PNG inside the throwaway data root.
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let file = URL(filePath: root).appending(path: "shot.png")
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            let project = doc.addProject(name: "media", folder: root, color: .orange)
            doc.addPane(to: project, content: .image(path: file.path))
        case "diff":
            // A throwaway repository with one uncommitted change.
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let repo = URL(filePath: root).appending(path: "repo")
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let file = repo.appending(path: "notes.txt")
            try? Data("alpha\nbeta\n".utf8).write(to: file)
            for arguments in [["init", "-q"], ["add", "."], ["commit", "-q", "-m", "seed"]] {
                let git = Process()
                git.executableURL = URL(filePath: "/usr/bin/git")
                git.arguments = ["-C", repo.path, "-c", "user.name=seed", "-c", "user.email=seed@local",
                                 "-c", "commit.gpgsign=false"] + arguments
                try? git.run()
                git.waitUntilExit()
            }
            try? Data("alpha\nbeta two\ngamma\n".utf8).write(to: file)
            let project = doc.addProject(name: "repo", folder: repo.path, color: .green)
            doc.addPane(to: project, content: .diff(path: nil, staged: false))
        case "web":
            // Port 9 (discard) is closed on a Mac: the page fails fast without touching the network.
            let project = doc.addProject(name: "site", folder: "/private/tmp", color: .blue)
            doc.addPane(to: project, content: .web(url: "http://127.0.0.1:9/", options: WebPaneOptions()))
        case "prompt":
            // Folder from -AletheUITestFolder (a folder the agent already trusts).
            let folder = UserDefaults.standard.string(forKey: "AletheUITestFolder") ?? "/private/tmp"
            let project = doc.addProject(name: "prompted", folder: folder, color: .purple)
            doc.addPane(to: project, tab: PaneTab(agent: "claude", initialPrompt: "/help"))
        default:
            break
        }
    }
}
#endif
