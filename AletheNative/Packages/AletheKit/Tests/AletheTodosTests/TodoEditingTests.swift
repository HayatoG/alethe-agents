import Foundation
import Testing
@testable import AlethePluginKit
@testable import AletheTodos

/// An in-memory file system for `TodoFileAccess` and plugin services.
actor MemoryFiles {
    private(set) var contents: [String: Data] = [:]
    private(set) var writes: [String] = []

    func read(_ url: URL) throws -> Data {
        guard let data = contents[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    func write(_ data: Data, _ url: URL) {
        contents[url.path] = data
        writes.append(url.path)
    }

    nonisolated var access: TodoFileAccess {
        TodoFileAccess(read: { try await self.read($0) }, write: { await self.write($0, $1) })
    }
}

@MainActor
@Suite struct TodoEditingTests {
    @Test func moveBetweenGlobalAndProjectKeepsOrderAndStamps() {
        let clock = Date(timeIntervalSince1970: 500)
        let store = TodoStore(storage: nil, now: { clock })
        let a = store.add(title: "A")!
        let b = store.add(title: "B", scope: .project("p1"))!
        store.move(a.id, to: .project("p1"))
        #expect(store.todos(in: .global).isEmpty)
        #expect(store.todos(in: .project("p1")).map(\.id) == [a.id, b.id])
        #expect(store.todo(id: a.id)?.projectID == "p1")
        store.move(b.id, to: .global)
        #expect(store.todos(in: .global).map(\.id) == [b.id])
        #expect(store.todos(in: .project("p2")).isEmpty)
        // Moving to the list it is already in changes nothing.
        let before = store.todos
        store.move(b.id, to: .global)
        #expect(store.todos == before)
    }

    @Test func editingTagsNormalizesAndCaps() {
        let store = TodoStore(storage: nil)
        let a = store.add(title: "Tagged", tags: ["old"])!
        store.setTags(a.id, ["#New", "new", "two words", "#x,y"])
        #expect(store.todo(id: a.id)?.tags == ["new", "two", "words", "x", "y"])
        store.setTags(a.id, ["a", "b", "c", "d", "e", "f", "g"])
        #expect(store.todo(id: a.id)?.tags.count == TodoRules.maxTags)
        store.setTags(a.id, [])
        #expect(store.todo(id: a.id)?.tags == [])
    }

    @Test func settingsClampPomodoroLengths() {
        let store = TodoStore(storage: nil)
        store.updateSettings {
            $0.pomodoroWorkMinutes = 0
            $0.pomodoroShortBreakMinutes = 500
            $0.pomodoroLongBreakMinutes = 20
        }
        #expect(store.settings.pomodoroWorkMinutes == 1)
        #expect(store.settings.pomodoroShortBreakMinutes == 120)
        #expect(store.settings.pomodoroLongBreakMinutes == 20)
        #expect(store.settings.pomodoroLengths.longBreak == 20 * 60)
    }

    @Test func resetToDefaultsReplacesTheList() {
        let store = TodoStore(storage: nil)
        store.add(title: "Mine", scope: .project("p"))
        store.resetToDefaults()
        #expect(store.todos.map(\.title) == TodoRules.defaultTitles.map(\.title))
        #expect(store.todos.allSatisfy { $0.projectID == nil && !$0.done })
    }

    @Test func templateThroughFileAccess() async throws {
        let files = MemoryFiles()
        let store = TodoStore(storage: nil)
        await #expect(throws: TodoTemplate.TemplateError.emptyDirectory) { try await store.ensureTemplate(using: files.access) }
        store.updateSettings { $0.storagePath = "/mem/todos" }
        #expect(store.templateURL?.path == "/mem/todos/\(TodoTemplate.fileName)")
        let url = try await store.ensureTemplate(using: files.access)
        #expect(try await files.read(url) == Data(TodoTemplate.defaultContent.utf8))
        // An existing template is never overwritten.
        await files.write(Data("// custom\n{\"todos\": [{\"title\": \"Custom\"}]}".utf8), url)
        _ = try await store.ensureTemplate(using: files.access)
        try await store.importTemplate(from: url, using: files.access)
        #expect(store.todos.map(\.title) == ["Custom"])

        store.add(title: "Round trip", tags: ["io"], scope: .project("p"), prURL: URL(string: "https://g/2"))
        store.toggle(store.todos[0].id)
        try await store.exportTemplate(to: url, using: files.access)
        let other = TodoStore(storage: nil)
        try await other.importTemplate(from: url, using: files.access)
        #expect(other.todos.map(\.id) == store.todos.map(\.id))
        #expect(other.todos.map(\.done) == store.todos.map(\.done))
        #expect(other.todos.map(\.tags) == store.todos.map(\.tags))
        #expect(other.todos.map(\.projectID) == store.todos.map(\.projectID))
        #expect(other.todos.map(\.prURL) == store.todos.map(\.prURL))
    }

    @Test func ensureRethrowsErrorsOtherThanAMissingFile() async {
        let denied = TodoFileAccess(read: { _ in throw CocoaError(.fileReadNoPermission) }, write: { _, _ in Issue.record("must not write") })
        await #expect(throws: CocoaError.self) {
            try await TodoTemplate.ensure(in: URL(filePath: "/locked", directoryHint: .isDirectory), using: denied)
        }
        #expect(TodoFileAccess.isMissingFile(POSIXError(.ENOENT)))
        #expect(!TodoFileAccess.isMissingFile(CocoaError(.fileReadNoPermission)))
    }
}

@MainActor
@Suite struct PomodoroStoreTests {
    @Test func focusTodoFollowsTheList() {
        let store = TodoStore(storage: nil)
        let a = store.add(title: "A")!
        let b = store.add(title: "B")!
        store.setFocus(a.id)
        #expect(store.pomodoro.focusTodoId == a.id)
        #expect(store.focusTodo?.id == a.id)
        store.toggle(a.id)
        #expect(store.pomodoro.focusTodoId == nil)
        store.setFocus(a.id)
        #expect(store.pomodoro.focusTodoId == nil)
        store.setFocus(b.id)
        store.delete(b.id)
        #expect(store.focusTodo == nil)
        #expect(store.pomodoro.focusTodoId == nil)
    }

    @Test func tickReportsEachPhaseEndOnce() {
        let clock = TestClock()
        let store = TodoStore(storage: nil, now: { clock.now })
        store.updateSettings { $0.pomodoroWorkMinutes = 1; $0.pomodoroShortBreakMinutes = 1 }
        #expect(store.tickPomodoro() == nil)
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        clock.advance(59)
        #expect(store.tickPomodoro() == nil)
        clock.advance(1)
        #expect(store.tickPomodoro() == .work)
        #expect(store.tickPomodoro() == nil)
        #expect(store.pomodoro.status == .finished)
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        #expect(store.pomodoro.phase == .shortBreak)
        clock.advance(61)
        #expect(store.tickPomodoro() == .shortBreak)
        #expect(store.pomodoro.cyclesCompleted == 1)
    }

    @Test func phaseEndedWhileClosedIsReportedOnceAfterRelaunch() async throws {
        let root = temporaryTodosDirectory()
        let start = Date(timeIntervalSince1970: 10_000)
        let store = TodoStore(storage: PluginStorage(root: root, pluginID: "p", debounce: .milliseconds(1)), now: { start })
        await store.load()
        let focus = store.add(title: "Focus")!
        store.setFocus(focus.id)
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        try await store.flush()

        let relaunched = TodoStore(storage: PluginStorage(root: root, pluginID: "p", debounce: .milliseconds(1)),
                                   now: { start.addingTimeInterval(30 * 60) })
        await relaunched.load()
        #expect(relaunched.pomodoro.status == .finished)
        #expect(relaunched.pomodoro.focusTodoId == focus.id)
        #expect(relaunched.tickPomodoro() == .work)
        #expect(relaunched.tickPomodoro() == nil)
        try await relaunched.flush()

        // The finished state was persisted: a second relaunch reports nothing.
        let again = TodoStore(storage: PluginStorage(root: root, pluginID: "p"), now: { start.addingTimeInterval(60 * 60) })
        await again.load()
        #expect(again.pomodoro.status == .finished)
        #expect(again.tickPomodoro() == nil)
    }

    @Test func runningSessionResumesAcrossRelaunch() async throws {
        let root = temporaryTodosDirectory()
        let start = Date(timeIntervalSince1970: 20_000)
        let store = TodoStore(storage: PluginStorage(root: root, pluginID: "p", debounce: .milliseconds(1)), now: { start })
        await store.load()
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        try await store.flush()
        let relaunched = TodoStore(storage: PluginStorage(root: root, pluginID: "p"), now: { start.addingTimeInterval(600) })
        await relaunched.load()
        #expect(relaunched.pomodoro.status == .running)
        #expect(relaunched.tickPomodoro() == nil)
        #expect(relaunched.pomodoro.remaining(now: start.addingTimeInterval(600)) == 15 * 60)
    }
}

/// A settable clock for `TodoStore(now:)`.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private func temporaryTodosDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AletheTodoEditingTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
