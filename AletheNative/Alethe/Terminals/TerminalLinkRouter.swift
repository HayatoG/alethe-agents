import AletheModel
import AletheTerminal
import AppKit

/// Opens a ⌘-clicked terminal link (upstream `XTermView` link actions): Markdown, images and videos in
/// a pane of the project (focusing one that already shows the file), other files in their default
/// app, folders in Finder, pages in the default browser, or in a web pane with ⌥ held.
extension AppEnvironment {
    func openTerminalLink(_ raw: String, from terminal: TerminalPaneView, tab: PaneTab, project: Project) {
        let cwd = terminal.reportedDirectory ?? tab.workingDirectory ?? project.folder
        let inPane = NSEvent.modifierFlags.contains(.option)
        switch TerminalLink.resolve(raw, cwd: cwd) {
        case .web(let url):
            if inPane {
                open(.web(url: url.absoluteString, options: WebPaneOptions()), in: project.id)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .file(let path, _):
            if let content = PaneContent.forFile(path) {
                open(content, in: project.id)
            } else {
                NSWorkspace.shared.open(URL(filePath: path))
            }
        case .directory(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
        case .other(let url):
            NSWorkspace.shared.open(url)
        case .none:
            NSSound.beep()
        }
    }

    /// Shows `content` in the project: focuses a pane already showing it, or adds one (undoable).
    private func open(_ content: PaneContent, in project: ProjectID) {
        guard let workspace else { return }
        if let existing = workspace.document.project(project)?.panes.first(where: { $0.content == content }) {
            workspace.update {
                $0.open(project)
                $0.workspace.focusedPaneID = existing.id
            }
            return
        }
        workspace.update(undoManager: NSApp.keyWindow?.undoManager, actionName: String(localized: "undo.openLink")) {
            $0.addPane(to: project, content: content)
        }
    }
}
