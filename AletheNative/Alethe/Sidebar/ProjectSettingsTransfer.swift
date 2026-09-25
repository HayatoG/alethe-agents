import AletheModel
import AppKit
import UniformTypeIdentifiers

/// Project menu › Export Settings… / Import Settings… (P5-6; upstream `sidebarMenus.tsx`). The file
/// holds settings only; an import lists what it changes, asks once and applies with undo.
@MainActor
enum ProjectSettingsTransfer {
    static func export(_ project: Project) {
        let panel = NSSavePanel()
        panel.title = String(localized: "projectSettings.export.title")
        panel.nameFieldStringValue = ProjectSettingsFile.suggestedFileName(for: project)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectSettingsFile(project: project).data().write(to: url, options: .atomic)
        } catch {
            inform(String(localized: "projectSettings.export.failed"), text: error.localizedDescription)
        }
    }

    static func importSettings(into projectID: ProjectID, workspace: WorkspaceModel, undoManager: UndoManager?) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "projectSettings.import.title")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file: ProjectSettingsFile
        do {
            file = try ProjectSettingsFile(data: Data(contentsOf: url))
        } catch {
            inform(String(localized: "projectSettings.import.failed"), text: String(localized: "projectSettings.import.invalid"))
            return
        }
        guard let project = workspace.document.project(projectID) else { return }
        let changes = file.changes(to: project)
        guard !changes.isEmpty else {
            inform(String(localized: "projectSettings.import.nothing"), text: "")
            return
        }
        let alert = NSAlert()
        alert.messageText = format("projectSettings.import.confirmTitle", project.name)
        alert.informativeText = changes.map { "• " + describe($0) }.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "projectSettings.import.apply"))
        alert.addButton(withTitle: String(localized: "editor.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.importProjectSettings")) {
            $0.updateProject(projectID) { file.apply(to: &$0) }
        }
    }

    static func describe(_ change: ProjectSettingsFile.Change) -> String {
        switch change {
        case .name(let from, let to):
            format("projectSettings.change.name", from, to)
        case .color(let from, let to):
            format("projectSettings.change.color", colorName(from), colorName(to))
        case .autoWorktree(let from, let to):
            format("projectSettings.change.autoWorktree", onOff(from), onOff(to))
        case .worktreeMode(let from, let to):
            format("projectSettings.change.worktreeMode", modeName(from), modeName(to))
        case .layoutMode(let from, let to):
            format("projectSettings.change.layout", layoutName(from), layoutName(to))
        case .githubURL(let from, let to):
            format("projectSettings.change.repository", from ?? "—", to ?? "—")
        }
    }

    private static func colorName(_ color: ProjectColor) -> String {
        String(localized: String.LocalizationValue("color.\(color.rawValue)"))
    }

    private static func onOff(_ value: Bool) -> String {
        String(localized: value ? "projectSettings.on" : "projectSettings.off")
    }

    private static func modeName(_ mode: ProjectWorktreeMode) -> String {
        String(localized: String.LocalizationValue("newTerminal.worktree.mode.\(mode.rawValue)"))
    }

    private static func layoutName(_ mode: PaneLayoutMode) -> String {
        String(localized: String.LocalizationValue("workspace.layout.\(mode.rawValue)"))
    }

    private static func inform(_ title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
