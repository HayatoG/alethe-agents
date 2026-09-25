import AletheModel
import AlethePluginKit
import SwiftUI

/// The selected project's Markdown files (P4-3); a click opens one in a Markdown pane.
struct DocsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.undoManager) private var undoManager
    @State private var files: [String] = []

    static let tabID = "docs"
    static let tab = SidebarTabContribution(id: tabID, title: "Docs", symbol: "doc.text", side: .right, viewID: tabID)

    private var project: Project? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)
        }
    }

    var body: some View {
        Group {
            if let project {
                if files.isEmpty {
                    ContentUnavailableView("docs.empty", systemImage: "doc.text")
                } else {
                    List(files, id: \.self) { path in
                        Button {
                            open(path, in: project.id)
                        } label: {
                            Label(relative(path, to: project.folder), systemImage: "doc.text")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help(path)
                    }
                    .listStyle(.sidebar)
                }
            } else {
                ContentUnavailableView("docs.noProject", systemImage: "folder")
            }
        }
        .task(id: project?.folder) {
            guard let folder = project?.folder else { files = []; return }
            files = await Task.detached { Self.scan(folder) }.value
        }
    }

    private func open(_ path: String, in project: ProjectID) {
        environment.workspace?.update(undoManager: undoManager, actionName: String(localized: "undo.addContent")) {
            $0.addPane(to: project, content: .markdown(path: path))
        }
    }

    private func relative(_ path: String, to folder: String) -> String {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
    }

    /// `*.md` / `*.markdown` files up to three levels deep, skipping hidden and dependency folders.
    nonisolated static func scan(_ folder: String, maxDepth: Int = 3, limit: Int = 200) -> [String] {
        let root = URL(filePath: folder, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let skipped: Set<String> = ["node_modules", "build", "target", "dist", "Pods", "DerivedData", "vendor", "Vendor"]
        var found: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(url.lastPathComponent) || enumerator.level >= maxDepth { enumerator.skipDescendants() }
                continue
            }
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                found.append(url.path)
                if found.count >= limit { break }
            }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
