import AlethePluginKit
import Foundation
import Observation

/// The todo list (global and per-project) and its settings, persisted through the plugin's
/// `PluginStorage` under the keys `todos` and `settings`. Ports upstream `plugins/todos/store.ts`:
/// active items stay ahead of completed ones, and a reorder never crosses that boundary.
@MainActor
@Observable
public final class TodoStore {
    static let todosKey = "todos"
    static let settingsKey = "settings"
    static let pomodoroKey = "pomodoro"

    /// Every todo, in visible order.
    public private(set) var todos: [Todo] = []
    public private(set) var settings = TodoSettings()
    /// The Pomodoro session, persisted so it survives relaunch.
    public private(set) var pomodoro = PomodoroTimer()
    public private(set) var isLoaded = false
    /// A phase that ended while the app was closed, reported once by `tickPomodoro()`.
    @ObservationIgnored private var pendingPhaseEnd: PomodoroTimer.Phase?

    @ObservationIgnored private let storage: PluginStorage?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    public init(storage: PluginStorage?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.now = now
    }

    /// Reads the stored list and settings. Unreadable entries fall back to empty/defaults.
    public func load() async {
        guard let storage else { isLoaded = true; return }
        let stored = (try? await storage.decode([Todo].self, forKey: Self.todosKey)) ?? nil
        let storedSettings = (try? await storage.decode(TodoSettings.self, forKey: Self.settingsKey)) ?? nil
        todos = Self.renumbered(stored ?? [])
        settings = storedSettings ?? TodoSettings()
        var timer = ((try? await storage.decode(PomodoroTimer.self, forKey: Self.pomodoroKey)) ?? nil) ?? PomodoroTimer()
        // A phase that ended while the app was closed surfaces as finished (and is notified once).
        pendingPhaseEnd = timer.tick(now: now())
        timer.validateFocus(against: todos)
        pomodoro = timer
        if pendingPhaseEnd != nil { persistPomodoro() }
        isLoaded = true
    }

    /// Todos of one list, in visible order.
    public func todos(in scope: TodoScope) -> [Todo] {
        todos.filter(scope.contains)
    }

    public func todo(id: String) -> Todo? {
        todos.first { $0.id == id }
    }

    // MARK: Mutations

    /// Adds an active todo after the last active one. Returns nil for an empty title.
    @discardableResult
    public func add(title: String, tags: [String] = [], scope: TodoScope = .global, prURL: URL? = nil) -> Todo? {
        let title = TodoRules.normalizeTitle(title)
        guard !title.isEmpty else { return nil }
        let todo = Todo(title: title, tags: TodoRules.normalizeTags(tags), prURL: prURL, projectID: scope.projectID, createdAt: now())
        var next = todos
        next.insert(todo, at: next.firstIndex(where: \.done) ?? next.endIndex)
        write(next)
        return self.todo(id: todo.id)
    }

    /// Adds a todo for a pull request, or returns the existing one with the same URL.
    @discardableResult
    public func addPullRequest(number: Int, title: String, url: URL, scope: TodoScope = .global) -> Todo? {
        if let existing = todos.first(where: { $0.prURL == url }) { return existing }
        return add(title: "PR #\(number): \(title)", tags: ["pr"], scope: scope, prURL: url)
    }

    public func rename(_ id: String, to title: String) {
        let title = TodoRules.normalizeTitle(title)
        guard !title.isEmpty else { return }
        update(id) { $0.title = title }
    }

    public func setTags(_ id: String, _ tags: [String]) {
        update(id) { $0.tags = TodoRules.normalizeTags(tags) }
    }

    public func addTag(_ id: String, _ tag: String) {
        guard let current = todo(id: id) else { return }
        setTags(id, current.tags + [tag])
    }

    public func removeTag(_ id: String, _ tag: String) {
        guard let current = todo(id: id) else { return }
        setTags(id, current.tags.filter { $0 != tag.lowercased() })
    }

    public func setPullRequestURL(_ id: String, _ url: URL?) {
        update(id) { $0.prURL = url }
    }

    /// Moves a todo between the global list and a project's list.
    public func move(_ id: String, to scope: TodoScope) {
        update(id) { $0.projectID = scope.projectID }
    }

    /// Completing moves the item to the end; reopening puts it after the last active item.
    public func toggle(_ id: String) {
        guard var changed = todo(id: id) else { return }
        changed.done.toggle()
        changed.updatedAt = now()
        var remaining = todos.filter { $0.id != id }
        if changed.done {
            remaining.append(changed)
        } else {
            remaining.insert(changed, at: remaining.firstIndex(where: \.done) ?? remaining.endIndex)
        }
        write(remaining)
    }

    public func delete(_ id: String) {
        write(todos.filter { $0.id != id })
    }

    /// Moves `draggedID` just before `targetID`. Ignored across the active/completed boundary.
    public func reorder(_ draggedID: String, onto targetID: String) {
        guard draggedID != targetID,
              let from = todos.firstIndex(where: { $0.id == draggedID }),
              let target = todos.firstIndex(where: { $0.id == targetID }),
              todos[from].done == todos[target].done
        else { return }
        var next = todos
        let dragged = next.remove(at: from)
        let adjusted = next.firstIndex { $0.id == targetID } ?? next.endIndex
        // Upstream semantics: the dragged item lands just before the target.
        next.insert(dragged, at: adjusted)
        write(next)
    }

    /// Replaces the list with upstream's three default todos.
    public func resetToDefaults() {
        write(TodoRules.defaultTitles.map { Todo(title: $0.title, tags: $0.tags, createdAt: now()) })
    }

    /// Replaces the whole list (template import).
    public func replaceAll(_ todos: [Todo]) {
        write(todos)
    }

    /// Applies a settings change; Pomodoro lengths are clamped to `TodoSettings.minuteRange`.
    public func updateSettings(_ change: (inout TodoSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.clamped()
        guard next != settings else { return }
        settings = next
        let snapshot = next
        enqueue { storage in try? await storage.encode(snapshot, forKey: Self.settingsKey) }
    }

    /// Applies a Pomodoro transition and persists the session. Returns what the closure returns
    /// (e.g. the phase `tick` finished).
    @discardableResult
    public func updatePomodoro<R>(_ change: (inout PomodoroTimer, _ lengths: PomodoroLengths, _ now: Date) -> R) -> R {
        var next = pomodoro
        let result = change(&next, settings.pomodoroLengths, now())
        if next != pomodoro {
            pomodoro = next
            persistPomodoro()
        }
        return result
    }

    /// Advances the session. Returns the phase that just ended, including one that ended while the
    /// app was closed (reported once, on the first tick after `load`).
    @discardableResult
    public func tickPomodoro() -> PomodoroTimer.Phase? {
        if let pending = pendingPhaseEnd {
            pendingPhaseEnd = nil
            return pending
        }
        return updatePomodoro { timer, _, now in timer.tick(now: now) }
    }

    /// Makes an active todo the Pomodoro focus; nil (or a completed/missing todo) clears it.
    public func setFocus(_ id: String?) {
        updatePomodoro { timer, _, _ in
            timer.focusTodoId = id
            timer.validateFocus(against: todos)
        }
    }

    /// The focused todo, if it is still active.
    public var focusTodo: Todo? {
        pomodoro.focusTodoId.flatMap(todo(id:)).flatMap { $0.done ? nil : $0 }
    }

    /// Waits for queued writes and flushes the storage file.
    public func flush() async throws {
        await pendingWrite?.value
        try await storage?.flush()
    }

    // MARK: Private

    private func update(_ id: String, _ change: (inout Todo) -> Void) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        var next = todos
        change(&next[index])
        guard next[index] != todos[index] else { return }
        next[index].updatedAt = now()
        write(next)
    }

    private func write(_ next: [Todo]) {
        todos = Self.renumbered(next)
        let snapshot = todos
        enqueue { storage in try? await storage.encode(snapshot, forKey: Self.todosKey) }
        // A completed or deleted todo stops being the focus.
        if pomodoro.focusTodoId != nil { updatePomodoro { timer, _, _ in timer.validateFocus(against: snapshot) } }
    }

    private func persistPomodoro() {
        let snapshot = pomodoro
        enqueue { storage in try? await storage.encode(snapshot, forKey: Self.pomodoroKey) }
    }

    /// Chains writes so they reach the storage actor in order.
    private func enqueue(_ operation: @escaping @Sendable (PluginStorage) async -> Void) {
        guard let storage else { return }
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            await operation(storage)
        }
    }

    private static func renumbered(_ todos: [Todo]) -> [Todo] {
        todos.enumerated().map { index, todo in
            var todo = todo
            todo.order = index
            return todo
        }
    }
}

extension TodoStore {
    /// The template file inside `settings.storagePath`.
    public var templateURL: URL? {
        let path = settings.storagePath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory).appending(path: TodoTemplate.fileName)
    }

    /// Creates the template in `settings.storagePath` when missing and returns its URL.
    public func ensureTemplate(using files: TodoFileAccess) async throws -> URL {
        guard let templateURL else { throw TodoTemplate.TemplateError.emptyDirectory }
        return try await TodoTemplate.ensure(in: templateURL.deletingLastPathComponent(), using: files)
    }

    /// Replaces the list with the todos read from a JSONC file.
    public func importTemplate(from url: URL, using files: TodoFileAccess) async throws {
        let todos = try TodoTemplate.parse(try await files.read(url), now: now())
        replaceAll(todos)
    }

    /// Writes the list back to a JSONC file.
    public func exportTemplate(to url: URL, using files: TodoFileAccess) async throws {
        try await files.write(TodoTemplate.render(todos), url)
    }
}
