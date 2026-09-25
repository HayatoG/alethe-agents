import AlethePluginKit
import Foundation

/// Built-in Todos plugin (upstream `plugins/todos`): a right-sidebar tab rendered by the app's
/// `todos` view and a "New Todo" command. Storage holds the list, settings and Pomodoro session;
/// the filesystem capabilities cover the external JSONC template.
@MainActor
public final class TodosPlugin: AlethePlugin {
    public static let manifest = PluginManifest(
        id: "com.alethe.todos",
        version: "1.0.0",
        name: "Todo List",
        capabilities: [.storage, .filesystemRead, .filesystemWrite]
    )

    public static let viewID = "todos"
    public static let sidebarTabID = "todos"
    public static let newTodoCommandID = "todos.new"

    /// The store of the active instance, for the app's views; nil while the plugin is disabled.
    public private(set) static var activeStore: TodoStore?
    /// Set by the app to reveal the tab and focus the new-todo field.
    public static var onNewTodo: (@MainActor () -> Void)?

    public private(set) var store: TodoStore?

    public init() {}

    public func activate(context: PluginContext) throws {
        let store = TodoStore(storage: try context.storage())
        try context.addSidebarTab(SidebarTabContribution(
            id: Self.sidebarTabID,
            title: "Todo",
            symbol: "checklist",
            side: .right,
            viewID: Self.viewID
        ))
        try context.addCommand(CommandContribution(
            id: Self.newTodoCommandID,
            title: "New Todo"
        ) {
            TodosPlugin.onNewTodo?()
        })
        self.store = store
        Self.activeStore = store
        Task { await store.load() }
    }

    public func deactivate() {
        if Self.activeStore === store { Self.activeStore = nil }
        store = nil
    }
}
