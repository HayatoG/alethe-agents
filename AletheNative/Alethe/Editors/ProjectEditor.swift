import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// New Project / Edit Project sheet.
struct ProjectEditor: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let editing: ProjectID?
    let initialLocation: ProjectLocation
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var metrics

    @State private var name = ""
    @State private var folder = ""
    @State private var color: ProjectColor? = .blue
    @State private var location: ProjectLocation = .ungrouped
    @State private var nameEdited = false

    var body: some View {
        Form {
            TextField(text: $folder, prompt: Text(verbatim: "~/Projects/app")) { Text("editor.project.folder") }
                .accessibilityIdentifier("editor.project.folder")
                .focused($focused)
                .onChange(of: folder) { _, value in
                    if !nameEdited, editing == nil { name = URL(filePath: expanded(value)).lastPathComponent }
                }
            HStack {
                Spacer()
                Button("editor.project.chooseFolder") { chooseFolder() }
            }
            TextField(text: Binding { name } set: { name = $0; nameEdited = true }) { Text("editor.project.name") }
                .accessibilityIdentifier("editor.project.name")
            LabeledContent("editor.color") { ColorSwatchPicker(selection: $color) }
            Picker(selection: $location) {
                Text("sidebar.ungrouped").tag(ProjectLocation.ungrouped)
                ForEach(workspace.document.groups) { group in
                    Text(verbatim: group.name).tag(ProjectLocation.group(group.id))
                }
            } label: { Text("editor.project.group") }
            if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .font(metrics.font(.footnote))
                    .accessibilityIdentifier("editor.problem")
            }
        }
        .formStyle(.grouped)
        .frame(width: metrics.size(460))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("editor.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "editor.project.create" : "editor.save") { save() }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("editor.confirm")
            }
        }
        .navigationTitle(Text(editing == nil ? "editor.project.newTitle" : "editor.project.editTitle"))
        .onAppear {
            focused = true
            loadInitial()
        }
    }

    /// Why the form cannot be saved yet, or nil.
    private var problem: LocalizedStringKey? {
        let path = expanded(folder)
        var isDirectory: ObjCBool = false
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "editor.problem.name" }
        if path.isEmpty || !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return "editor.problem.folder"
        }
        let standardized = URL(filePath: path).standardizedFileURL.path
        if workspace.document.projects.contains(where: {
            URL(filePath: $0.folder).standardizedFileURL.path == standardized && $0.id != editing
        }) {
            return "editor.problem.duplicate"
        }
        return nil
    }

    private func expanded(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    private func loadInitial() {
        location = initialLocation
        guard let editing, let project = workspace.document.project(editing) else { return }
        name = project.name
        folder = project.folder
        color = project.color
        location = workspace.document.location(of: editing) ?? .ungrouped
        nameEdited = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func save() {
        let path = URL(filePath: expanded(folder)).standardizedFileURL.path
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let color = color ?? .blue
        if let editing {
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.editProject")) { doc in
                doc.updateProject(editing) {
                    $0.name = trimmed
                    $0.folder = path
                    $0.color = color
                }
                if doc.location(of: editing) != location { doc.moveProject(editing, to: location, at: Int.max) }
            }
        } else {
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.addProject")) { doc in
                let id = doc.addProject(name: trimmed, folder: path, color: color, in: location)
                doc.open(id)
            }
        }
        dismiss()
    }
}
