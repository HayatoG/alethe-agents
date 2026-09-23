#if DEBUG
import AletheModel
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
        default:
            break
        }
    }
}
#endif
