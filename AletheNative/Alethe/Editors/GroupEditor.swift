import AletheDesign
import AletheModel
import SwiftUI

/// New Group / Edit Group sheet.
struct GroupEditor: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let editing: GroupID?
    let initialParent: GroupID?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var metrics

    @State private var name = ""
    @State private var color: ProjectColor?
    @State private var parent: GroupID?

    var body: some View {
        Form {
            TextField(text: $name) { Text("editor.group.name") }
                .accessibilityIdentifier("editor.group.name")
                .focused($focused)
            LabeledContent("editor.color") { ColorSwatchPicker(selection: $color, allowsNone: true) }
            Picker(selection: $parent) {
                Text("editor.group.topLevel").tag(GroupID?.none)
                ForEach(parentCandidates) { group in
                    Text(verbatim: group.name).tag(GroupID?.some(group.id))
                }
            } label: { Text("editor.group.parent") }
        }
        .formStyle(.grouped)
        .frame(width: metrics.size(420))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("editor.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "editor.group.create" : "editor.save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("editor.confirm")
            }
        }
        .navigationTitle(Text(editing == nil ? "editor.group.newTitle" : "editor.group.editTitle"))
        .onAppear {
            focused = true
            parent = initialParent
            if let editing, let group = workspace.document.group(editing) {
                name = group.name
                color = group.color
                parent = group.parentID
            }
        }
    }

    /// A group cannot be nested inside itself or its descendants.
    private var parentCandidates: [ProjectGroup] {
        workspace.document.groups.filter { candidate in
            guard let editing else { return true }
            return !workspace.document.isGroup(candidate.id, inside: editing)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let editing {
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.editGroup")) { doc in
                doc.updateGroup(editing) {
                    $0.name = trimmed
                    $0.color = color
                }
                if doc.group(editing)?.parentID != parent { doc.moveGroup(editing, toParent: parent, at: Int.max) }
            }
        } else {
            workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newGroup")) {
                _ = $0.addGroup(name: trimmed, color: color, parent: parent)
            }
        }
        dismiss()
    }
}
