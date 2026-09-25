import AletheModel
import AletheTodos
import SwiftUI

/// The Todos plugin's `todos` view (P4-16): the global list and the selected project's list.
struct TodosView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var draft = ""
    @State private var addToProject = true
    @State private var editingID: String?
    @State private var editingTitle = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case draft, rename }

    private var project: Project? {
        environment.workspace.flatMap { model in
            model.document.workspace.selectedProjectID.flatMap(model.document.project)
        }
    }

    var body: some View {
        if let store = TodosPlugin.activeStore {
            VStack(spacing: 0) {
                PomodoroPill(store: store)
                    .padding(.top, 8)
                addRow(store)
                List {
                    if let project {
                        section(store, scope: .project(project.id.rawValue), title: Text(project.name))
                    }
                    section(store, scope: .global, title: Text("todos.global"))
                }
                .listStyle(.sidebar)
            }
            .onChange(of: environment.newTodoRequest) { focus = .draft }
        } else {
            ContentUnavailableView("todos.disabled", systemImage: "checklist")
        }
    }

    private func addRow(_ store: TodoStore) -> some View {
        HStack(spacing: 6) {
            TextField("todos.new.placeholder", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .draft)
                .onSubmit { add(store) }
            if project != nil {
                Toggle(isOn: $addToProject) { Image(systemName: "folder") }
                    .toggleStyle(.button)
                    .help("todos.new.toProject")
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func section(_ store: TodoStore, scope: TodoScope, title: Text) -> some View {
        let items = store.todos(in: scope)
        Section {
            if items.isEmpty {
                Text("todos.empty").foregroundStyle(.secondary)
            }
            ForEach(items) { todo in
                row(store, todo)
                    .draggable(todo.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = ids.first else { return false }
                        store.reorder(dragged, onto: todo.id)
                        return true
                    }
            }
        } header: {
            title
        }
    }

    private func row(_ store: TodoStore, _ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                store.toggle(todo.id)
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(todo.done ? "todos.reopen" : "todos.complete"))
            VStack(alignment: .leading, spacing: 2) {
                if editingID == todo.id {
                    TextField("todos.rename", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .rename)
                        .onSubmit { commitRename(store) }
                        .onExitCommand { editingID = nil }
                } else {
                    Text(todo.title)
                        .strikethrough(todo.done)
                        .foregroundStyle(todo.done ? .secondary : .primary)
                        .onTapGesture(count: 2) { beginRename(todo) }
                }
                if !todo.tags.isEmpty {
                    Text(todo.tags.map { "#" + $0 }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("todos.rename") { beginRename(todo) }
            Button("todos.delete", role: .destructive) { store.delete(todo.id) }
        }
    }

    private func add(_ store: TodoStore) {
        // `#word` tokens become tags.
        let words = draft.split(separator: " ").map(String.init)
        let tags = words.filter { $0.count > 1 && $0.hasPrefix("#") }.map { String($0.dropFirst()) }
        let title = words.filter { !($0.count > 1 && $0.hasPrefix("#")) }.joined(separator: " ")
        let scope: TodoScope = addToProject ? project.map { .project($0.id.rawValue) } ?? .global : .global
        if store.add(title: title, tags: tags, scope: scope) != nil { draft = "" }
    }

    private func beginRename(_ todo: Todo) {
        editingTitle = todo.title
        editingID = todo.id
        focus = .rename
    }

    private func commitRename(_ store: TodoStore) {
        if let editingID { store.rename(editingID, to: editingTitle) }
        editingID = nil
    }
}
