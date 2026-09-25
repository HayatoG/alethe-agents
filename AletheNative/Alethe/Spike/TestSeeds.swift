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
        case "cliOpen":
            // Two projects in their own folders inside the throwaway data root, neither shown (P5-8).
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            for name in ["api", "web"] {
                let folder = URL(filePath: root).appending(path: name)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                doc.addProject(name: name, folder: folder.path, color: .teal)
            }
        case "terminals":
            let project = doc.addProject(name: "scratch", folder: "/private/tmp", color: .pink)
            doc.addPane(to: project, tab: PaneTab(agent: "claude"))
        case "panes":
            let api = doc.addProject(name: "api", folder: "/private/tmp", color: .orange)
            let web = doc.addProject(name: "web", folder: "/private/tmp", color: .teal)
            for title in ["one", "two", "three"] { doc.addPane(to: api, tab: PaneTab(agent: "shell", title: title)) }
            doc.addPane(to: web, tab: PaneTab(agent: "shell", title: "four"))
        case "grid":
            // Three panes in a 2×2 custom grid: one, two on top, three below with a free slot beside it.
            let api = doc.addProject(name: "api", folder: "/private/tmp", color: .orange)
            let panes = ["one", "two", "three"].compactMap { doc.addPane(to: api, tab: PaneTab(agent: "shell", title: $0)) }
            doc.setGridLayout(.auto(panes.map(\.rawValue)), for: api)
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
            let repo = seedRepository()
            let project = doc.addProject(name: "repo", folder: repo.path, color: .green)
            doc.addPane(to: project, content: .diff(path: nil, staged: false))
        case "git":
            // The same repository plus an untracked file, for Git Control (P4-5).
            let repo = seedRepository()
            try? Data("draft\n".utf8).write(to: repo.appending(path: "draft.txt"))
            _ = doc.addProject(name: "repo", folder: repo.path, color: .green)
        case "worktrees":
            // A throwaway repository with one locked agent worktree (P4-9).
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let repo = URL(filePath: root).appending(path: "wtrepo")
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try? Data("seed\n".utf8).write(to: repo.appending(path: "README.md"))
            let worktree = repo.appending(path: ".alethe/worktrees/seed").path
            for arguments in [["init", "-q"], ["add", "."], ["commit", "-q", "-m", "seed"],
                              ["worktree", "add", "-q", "-b", "alethe/agent-seed", worktree, "HEAD"],
                              ["worktree", "lock", "--reason", "seeded", worktree]] {
                let git = Process()
                git.executableURL = URL(filePath: "/usr/bin/git")
                git.arguments = ["-C", repo.path, "-c", "user.name=seed", "-c", "user.email=seed@local",
                                 "-c", "commit.gpgsign=false"] + arguments
                try? git.run()
                git.waitUntilExit()
            }
            _ = doc.addProject(name: "wtrepo", folder: repo.path, color: .green)
        case "clone":
            // A local bare repository (`origin.git` in the data root) to clone from (P5-5).
            let repo = seedRepository()
            let bare = repo.deletingLastPathComponent().appending(path: "origin.git")
            let git = Process()
            git.executableURL = URL(filePath: "/usr/bin/git")
            git.arguments = ["clone", "-q", "--bare", "--", repo.path, bare.path]
            try? git.run()
            git.waitUntilExit()
            _ = doc.addProject(name: "repo", folder: repo.path, color: .green)
        case "agentLibrary":
            // A project in the data root whose `.claude/agents` holds one agent Alethe did not write (P5-16).
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let folder = URL(filePath: root).appending(path: "agentsproj")
            let agents = folder.appending(path: ".claude/agents")
            try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try? Data("---\nname: mine\ndescription: My own agent.\n---\n".utf8).write(to: agents.appending(path: "mine.md"))
            _ = doc.addProject(name: "agentsproj", folder: folder.path, color: .purple)
        case "web":
            // Port 9 (discard) is closed on a Mac: the page fails fast without touching the network.
            let project = doc.addProject(name: "site", folder: "/private/tmp", color: .blue)
            doc.addPane(to: project, content: .web(url: "http://127.0.0.1:9/", options: WebPaneOptions()))
        case "graphify":
            // A repository with a Graphify graph and one older, smaller snapshot; no pane yet (P5-23).
            let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
            let repo = URL(filePath: root).appending(path: "graphrepo")
            let graph = #"{"nodes":[{"id":"alpha","label":"alpha","source_file":"README.md","community":0},{"id":"beta","label":"beta","community":0},{"id":"delta","label":"delta","community":1},{"id":"epsilon","label":"epsilon","community":1}],"edges":[{"source":"alpha","target":"beta"},{"source":"beta","target":"delta"},{"source":"delta","target":"epsilon"}]}"#
            let older = #"{"nodes":[{"id":"alpha"},{"id":"beta"}],"edges":[{"source":"alpha","target":"beta"}]}"#
            for folder in [".git", "graphify-out", ".alethe/graph-snapshots"] {
                try? FileManager.default.createDirectory(at: repo.appending(path: folder), withIntermediateDirectories: true)
            }
            try? Data("# Graph\n".utf8).write(to: repo.appending(path: "README.md"))
            try? Data(graph.utf8).write(to: repo.appending(path: "graphify-out/graph.json"))
            try? Data(older.utf8).write(to: repo.appending(path: ".alethe/graph-snapshots/1750000000000.json"))
            _ = doc.addProject(name: "graphrepo", folder: repo.path, color: .purple)
        case "skills":
            seedSkills()
        case "gsdSync":
            // A repository with a GSD Sync child session mid-planning, in a project holding a disabled
            // OpenCode tab: GSD Sync is available without spawning OpenCode (P5-24).
            let repo = seedPlanningRepository()
            let project = doc.addProject(name: "gsdproj", folder: repo.path, color: .purple)
            if let pane = doc.addPane(to: project, tab: PaneTab(agent: "opencode")) { doc.setDisabled(pane, true) }
            doc.workspace.selectedProjectID = project
        case "prompt":
            // Folder from -AletheUITestFolder (a folder the agent already trusts).
            let folder = UserDefaults.standard.string(forKey: "AletheUITestFolder") ?? "/private/tmp"
            let project = doc.addProject(name: "prompted", folder: folder, color: .purple)
            doc.addPane(to: project, tab: PaneTab(agent: "claude", initialPrompt: "/help"))
        default:
            break
        }
    }

    /// Preferences a seed needs (applied with the workspace seed).
    static func apply(_ name: String, to preferences: inout PreferencesDocument) {
        switch name {
        case "gsdSync":
            preferences.features.set(.gsdSync, on: true)
        default:
            break
        }
    }

    /// `gsdrepo` in the data root: a repository whose `.planning/` has a busy child session, a
    /// status and a three-item roadmap with one item checked.
    private static func seedPlanningRepository() -> URL {
        let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
        let repo = URL(filePath: root).appending(path: "gsdrepo")
        let planning = repo.appending(path: ".planning")
        try? FileManager.default.createDirectory(at: planning, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/git")
        git.arguments = ["-C", repo.path, "init", "-q"]
        try? git.run()
        git.waitUntilExit()
        let files = [
            ".gsd-child-session": "ses_seededchild\n",
            ".gsd-child-busy": "",
            "status.md": "Status: In Progress\nProgress: 40%\n",
            "task.md": "- [x] Map the API\n- [ ] Write the client\n- [ ] Ship it\n",
            "plan.md": "# Plan\n\n1. Map the API\n",
        ]
        for (name, text) in files { try? Data(text.utf8).write(to: planning.appending(path: name)) }
        return repo
    }

    /// Skills in the `-AletheIntegrationsHome` folder (P5-15): `brand` in the shared store linked
    /// from Claude Code, `motion` only in Claude Code, and Codex's bundled `imagegen`.
    private static func seedSkills() {
        guard let home = UserDefaults.standard.string(forKey: "AletheIntegrationsHome") else { return }
        let root = URL(filePath: home, directoryHint: .isDirectory)
        func skill(_ path: String, _ text: String) -> URL {
            let dir = root.appending(path: path, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: dir.appending(path: "SKILL.md"))
            return dir
        }
        let brand = skill(".agents/skills/brand", "---\nname: brand\ndescription: Brand system\n---\n\n# Brand\n\nUse the palette.\n")
        try? FileManager.default.createDirectory(at: root.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: root.appending(path: ".claude/skills/brand"), withDestinationURL: brand)
        let motion = skill(".claude/skills/motion", "---\nname: motion\ndescription: >\n  Creates motion\n  graphics\n---\n\n# Motion guide\n")
        try? FileManager.default.createDirectory(at: motion.appending(path: "references"), withIntermediateDirectories: true)
        try? Data("notes".utf8).write(to: motion.appending(path: "references/timing.md"))
        _ = skill(".codex/skills/.system/imagegen", "---\ndescription: Generates images\n---\n\n# Images\n")
    }

    /// `repo` in the data root: `notes.txt` committed on `main`, then modified in the worktree.
    private static func seedRepository() -> URL {
        let root = UserDefaults.standard.string(forKey: "AletheDataRoot") ?? "/private/tmp"
        let repo = URL(filePath: root).appending(path: "repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let file = repo.appending(path: "notes.txt")
        try? Data("alpha\nbeta\n".utf8).write(to: file)
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "seed"]] {
            let git = Process()
            git.executableURL = URL(filePath: "/usr/bin/git")
            git.arguments = ["-C", repo.path, "-c", "user.name=seed", "-c", "user.email=seed@local",
                             "-c", "commit.gpgsign=false"] + arguments
            try? git.run()
            git.waitUntilExit()
        }
        try? Data("alpha\nbeta two\ngamma\n".utf8).write(to: file)
        return repo
    }
}
#endif
