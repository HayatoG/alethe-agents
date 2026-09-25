import AletheDesign
import AletheFiles
import AletheFoundation
import AletheGit
import AletheModel
import AlethePluginKit
import AppKit
import Quartz
import SwiftUI

/// File explorer for the selected project's folder (P4-8): lazy tree, git badges, live refresh.
struct FilesView: View {
    @Environment(AppEnvironment.self) private var environment

    static let tabID = "files"
    static let tab = SidebarTabContribution(id: tabID, title: "Files", symbol: "folder", side: .right, viewID: tabID)

    private var project: Project? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)
        }
    }

    var body: some View {
        if let project {
            FileTreeList(project: project).id(project.folder)
        } else {
            ContentUnavailableView("docs.noProject", systemImage: "folder")
        }
    }
}

private struct FileTreeList: View {
    let project: Project
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var tree: FileTree
    @State private var renaming: URL?
    @State private var draftName = ""
    @State private var pendingDelete: URL?
    @State private var errorMessage: String? { didSet { if errorMessage != oldValue { AppLog.shown(errorMessage, .app) } } }
    @State private var selection: URL?
    @FocusState private var renameFocused: Bool

    init(project: Project) {
        self.project = project
        _tree = State(initialValue: FileTree(root: URL(filePath: project.folder, directoryHint: .isDirectory)))
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(tree.visibleRows()) { row in
                rowView(row)
                    .tag(row.node.url)
                    .contextMenu { menu(for: row.node) }
            }
        }
        .listStyle(.sidebar)
        .contextMenu { createMenu(in: tree.root) }
        .onKeyPress(.space) {
            guard renaming == nil, let selection else { return .ignored }
            QuickLook.shared.show(selection)
            return .handled
        }
        .overlay {
            if tree.rootNodes.isEmpty { ContentUnavailableView("files.empty", systemImage: "folder") }
        }
        .task { await follow() }
        .confirmationDialog("files.deletePermanently.title", isPresented: deleteBinding, presenting: pendingDelete) { url in
            Button("files.deletePermanently", role: .destructive) { deletePermanently(url) }
        } message: { url in
            Text(verbatim: String(format: String(localized: "files.deletePermanently.message"), url.lastPathComponent))
        }
        .alert("files.error", isPresented: errorBinding) {
            Button("files.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: FileTreeRow) -> some View {
        let node = row.node
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(theme[.textTertiary])
                .opacity(node.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: node.isDirectory && row.isExpanded ? FileIcons.openFolderSymbol : node.iconName)
                .foregroundStyle(node.isDirectory ? theme[.accent] : theme[.textSecondary])
                .frame(width: 16)
            if renaming == node.url {
                TextField("files.name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(node.url) }
                    .onExitCommand { renaming = nil }
                    .onAppear { renameFocused = true }
            } else {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(badgeColor(tree.badge(for: node)) ?? theme[.textPrimary])
            }
            Spacer(minLength: 4)
            if let badge = tree.badge(for: node) {
                Text(badge.letter)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(badgeColor(badge) ?? theme[.textSecondary])
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = node.url
            activate(node)
        }
        .help(node.url.path)
    }

    private func badgeColor(_ badge: GitBadge?) -> Color? {
        switch badge {
        case .conflict?, .deleted?: theme[.statusStopped]
        case .modified?, .stagedModified?, .renamed?: theme[.statusWaiting]
        case .added?, .untracked?: theme[.statusActive]
        case nil: nil
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        if !node.isDirectory {
            Button("files.open") { open(node) }
            Button("files.openWithDefaultApp") { NSWorkspace.shared.open(node.url) }
        }
        Button("files.quickLook") { QuickLook.shared.show(node.url) }
        Button("files.revealInFinder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Divider()
        Button("files.rename") {
            draftName = node.name
            renaming = node.url
        }
        createMenu(in: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
        Divider()
        Button("files.moveToTrash", role: .destructive) { trash(node.url) }
    }

    @ViewBuilder
    private func createMenu(in directory: URL) -> some View {
        Button("files.newFile") { create(in: directory, folder: false) }
        Button("files.newFolder") { create(in: directory, folder: true) }
    }

    // MARK: Actions

    private func activate(_ node: FileNode) {
        if node.isDirectory {
            attempt { try tree.toggle(node.url) }
        } else {
            open(node)
        }
    }

    /// Opens a file in the pane its kind maps to; plain text goes to the default app.
    private func open(_ node: FileNode) {
        let path = node.url.path
        let content: PaneContent? = switch node.paneKind {
        case .markdown?: .markdown(path: path)
        case .image?: .image(path: path)
        case .video?: .video(path: path)
        case .web?: environment.features.isOn(.browser) ? .web(url: node.url.absoluteString, options: WebPaneOptions()) : nil
        case .text?, nil: nil
        }
        if let content {
            environment.open(content, in: project.id)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    private func commitRename(_ url: URL) {
        renaming = nil
        attempt {
            try FileOperations.rename(url, to: draftName)
            try tree.reload()
        }
    }

    /// Creates `untitled` (numbered when taken), then starts renaming it inline.
    private func create(in directory: URL, folder: Bool) {
        let base = String(localized: folder ? "files.untitledFolder" : "files.untitledFile")
        var name = base
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(index)"
            index += 1
        }
        attempt {
            let created = folder
                ? try FileOperations.createFolder(named: name, in: directory)
                : try FileOperations.createFile(named: name, in: directory)
            if directory.standardizedFileURL != tree.root { try tree.expand(directory) }
            try tree.reload()
            draftName = name
            renaming = created.standardizedFileURL
        }
    }

    private func trash(_ url: URL) {
        attempt {
            if try FileOperations.moveToTrash(url) == .trashUnavailable {
                pendingDelete = url
            }
            try tree.reload()
        }
    }

    private func deletePermanently(_ url: URL) {
        pendingDelete = nil
        attempt {
            try FileOperations.deletePermanently(url)
            try tree.reload()
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch let error as FileOperationError {
            errorMessage = switch error {
            case .invalidName: String(localized: "files.error.invalidName")
            case .alreadyExists: String(localized: "files.error.alreadyExists")
            case .notFound: String(localized: "files.error.notFound")
            case .rootNotModifiable: String(localized: "files.error.root")
            case .failed(let message): message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Live refresh

    /// Loads the tree and git badges, then refreshes both on every watcher signal until cancelled.
    private func follow() async {
        try? tree.reload()
        let repository: GitRepository? = if let root = try? await GitRepository.discover(tree.root) {
            GitRepositories.shared.repository(at: root)
        } else {
            nil
        }
        await refreshBadges(repository)
        // With the folder below the repository root, `.git` lies outside the tree watcher: watch it
        // too, so commits, stages and checkouts refresh the badges.
        let gitWatcher = repository.flatMap { Self.gitDirectoryWatcher(repoRoot: $0.root, tree: tree.root) }
        gitWatcher?.start()
        let gitRefresh = gitWatcher.map { watcher in
            Task { @MainActor in
                for await _ in watcher.events { await refreshBadges(repository) }
            }
        }
        let watcher = FileTreeWatcher(root: tree.root)
        watcher.start()
        defer {
            watcher.stop()
            gitWatcher?.stop()
            gitRefresh?.cancel()
        }
        for await _ in watcher.events {
            try? tree.reload()
            await refreshBadges(repository)
        }
    }

    /// A watcher on the repository's `.git` when it is not inside the watched folder.
    private static func gitDirectoryWatcher(repoRoot: URL, tree: URL) -> GitWatcher? {
        let root = repoRoot.standardizedFileURL.resolvingSymlinksInPath()
        let folder = tree.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != folder.path else { return nil }
        var gitDirectory = root.appending(path: ".git", directoryHint: .isDirectory)
        // A worktree or submodule has a `.git` file pointing at its git directory.
        if let text = try? String(contentsOf: root.appending(path: ".git"), encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(filePath: path, directoryHint: .isDirectory, relativeTo: root).standardizedFileURL
        }
        return GitWatcher(root: gitDirectory)
    }

    private func refreshBadges(_ repository: GitRepository?) async {
        guard let repository, let status = try? await repository.status() else {
            tree.gitBadges = nil
            return
        }
        tree.gitBadges = GitBadgeIndex(status: status, repoRoot: repository.root)
    }

    private var deleteBinding: Binding<Bool> {
        Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } }
    }

    private var errorBinding: Binding<Bool> {
        Binding { errorMessage != nil } set: { if !$0 { errorMessage = nil } }
    }
}

/// Shows one file in the shared Quick Look panel (Space in the explorer).
@MainActor
private final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    /// Only touched on the main thread (Quick Look queries its data source there).
    nonisolated(unsafe) private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }
}
