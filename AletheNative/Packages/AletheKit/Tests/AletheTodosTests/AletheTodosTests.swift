import Foundation
import Testing
@testable import AlethePluginKit
@testable import AletheTodos

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AletheTodosTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Suite struct TodoStoreTests {
    @Test func addInsertsBeforeCompletedAndNormalizes() {
        let store = TodoStore(storage: nil)
        let a = store.add(title: "  A  ", tags: ["#Review", "review", "a b!"])!
        #expect(a.title == "A")
        #expect(a.tags == ["review", "a", "b"])
        #expect(store.add(title: "   ") == nil)
        let b = store.add(title: "B")!
        store.toggle(a.id)
        let c = store.add(title: "C")!
        #expect(store.todos.map(\.id) == [b.id, c.id, a.id])
        #expect(store.todos.map(\.order) == [0, 1, 2])
        store.toggle(a.id)
        #expect(store.todos.map(\.id) == [b.id, c.id, a.id])
        #expect(store.todo(id: a.id)?.done == false)
    }

    @Test func editTagsDeleteAndScopes() {
        let store = TodoStore(storage: nil)
        let a = store.add(title: "Global")!
        let b = store.add(title: "Mine", scope: .project("p1"))!
        store.rename(a.id, to: "Renamed")
        store.rename(a.id, to: "  ")
        store.addTag(a.id, "Bug")
        store.addTag(a.id, "bug")
        store.removeTag(a.id, "BUG")
        store.addTag(a.id, "ui")
        #expect(store.todo(id: a.id)?.title == "Renamed")
        #expect(store.todo(id: a.id)?.tags == ["ui"])
        #expect(store.todos(in: .global).map(\.id) == [a.id])
        #expect(store.todos(in: .project("p1")).map(\.id) == [b.id])
        store.move(b.id, to: .global)
        #expect(store.todos(in: .project("p1")).isEmpty)
        store.delete(a.id)
        #expect(store.todos.map(\.id) == [b.id])
    }

    @Test func reorderStaysWithinCompletionGroup() {
        let store = TodoStore(storage: nil)
        let a = store.add(title: "A")!, b = store.add(title: "B")!, c = store.add(title: "C")!
        let d = store.add(title: "D")!
        store.toggle(d.id)
        store.reorder(c.id, onto: a.id)
        #expect(store.todos.map(\.title) == ["C", "A", "B", "D"])
        store.reorder(c.id, onto: b.id)
        #expect(store.todos.map(\.title) == ["A", "C", "B", "D"])
        store.reorder(a.id, onto: d.id)
        #expect(store.todos.map(\.title) == ["A", "C", "B", "D"])
        #expect(store.todos.map(\.order) == [0, 1, 2, 3])
        _ = b
    }

    @Test func pullRequestTodosAreDeduplicated() {
        let store = TodoStore(storage: nil)
        let url = URL(string: "https://github.com/o/r/pull/7")!
        let first = store.addPullRequest(number: 7, title: "Fix", url: url)!
        let again = store.addPullRequest(number: 7, title: "Fix", url: url)!
        #expect(first.id == again.id)
        #expect(first.title == "PR #7: Fix")
        #expect(first.tags == ["pr"])
        #expect(store.todos.count == 1)
    }

    @Test func persistenceRoundTripThroughPluginStorage() async throws {
        let root = temporaryDirectory()
        let storage = PluginStorage(root: root, pluginID: TodosPlugin.manifest.id, debounce: .milliseconds(1))
        let store = TodoStore(storage: storage)
        await store.load()
        let a = store.add(title: "Persist me", tags: ["x"], scope: .project("p"))!
        store.add(title: "Second")
        store.toggle(a.id)
        store.setPullRequestURL(a.id, URL(string: "https://example.com/pr/1"))
        store.updateSettings { $0.storagePath = "/tmp/todos"; $0.pomodoroWorkMinutes = 50 }
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        try await store.flush()

        let reopened = TodoStore(storage: PluginStorage(root: root, pluginID: TodosPlugin.manifest.id))
        await reopened.load()
        #expect(reopened.todos == store.todos)
        #expect(reopened.settings.storagePath == "/tmp/todos")
        #expect(reopened.settings.pomodoroWorkMinutes == 50)
        #expect(reopened.pomodoro.status == .running)
        #expect(reopened.pomodoro.phase == .work)
    }

    @Test func expiredPomodoroSessionLoadsAsFinished() async throws {
        let root = temporaryDirectory()
        let start = Date(timeIntervalSince1970: 1_000)
        let store = TodoStore(storage: PluginStorage(root: root, pluginID: "t", debounce: .milliseconds(1)), now: { start })
        await store.load()
        store.updatePomodoro { timer, lengths, now in timer.start(lengths: lengths, now: now) }
        try await store.flush()
        let later = TodoStore(storage: PluginStorage(root: root, pluginID: "t"), now: { start.addingTimeInterval(3_600) })
        await later.load()
        #expect(later.pomodoro.status == .finished)
        #expect(later.pomodoro.cyclesCompleted == 1)
    }
}

@Suite struct TodoTemplateTests {
    @Test func parsesUpstreamTemplate() throws {
        let todos = try TodoTemplate.parse(Data(TodoTemplate.defaultContent.utf8))
        #expect(todos.map(\.id) == ["task-example-1"])
        #expect(todos.first?.title == "Example task")
        #expect(todos.first?.done == false)
    }

    @Test func parsesOptionalFieldsAndSkipsInvalidEntries() throws {
        let source = """
        { "todos": [
          { "id": "x", "title": "One", "completed": true, "tags": ["A"], "projectId": "p", "prUrl": "https://g/1", },
          { "title": "  " },
          { "id": "x", "title": "Dup id" },
        ], }
        """
        let todos = try TodoTemplate.parse(Data(source.utf8))
        #expect(todos.count == 2)
        #expect(todos[0].done && todos[0].tags == ["a"] && todos[0].projectID == "p")
        #expect(todos[0].prURL?.absoluteString == "https://g/1")
        #expect(todos[1].id != "x")
        #expect(throws: TodoTemplate.TemplateError.self) { try TodoTemplate.parse(Data("{ nope".utf8)) }
    }

    @Test func ensureCreatesOnceAndNeverOverwrites() throws {
        let directory = temporaryDirectory().appending(path: "nested/dir")
        let url = try TodoTemplate.ensure(in: directory)
        #expect(url.lastPathComponent == TodoTemplate.fileName)
        #expect(try String(contentsOf: url, encoding: .utf8) == TodoTemplate.defaultContent)
        try Data("// custom\n{\"todos\": []}".utf8).write(to: url)
        try TodoTemplate.ensure(in: directory)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("// custom"))
    }
}

@MainActor
@Suite(.serialized) struct TodosPluginTests {
    @Test func activationContributesTabAndCommand() async throws {
        let host = PluginHost(plugins: [TodosPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        #expect(host.record(for: TodosPlugin.manifest.id)?.state == .active)
        let tab = try #require(host.contributions.sidebarTabs.first)
        #expect(tab.viewID == "todos")
        #expect(tab.side == .right)
        let command = try #require(host.contributions.commands.first)
        #expect(command.id == TodosPlugin.newTodoCommandID)
        #expect(TodosPlugin.activeStore != nil)

        var fired = false
        TodosPlugin.onNewTodo = { fired = true }
        command.perform()
        #expect(fired)
        TodosPlugin.onNewTodo = nil

        try await host.setEnabled(false, for: TodosPlugin.manifest.id)
        #expect(TodosPlugin.activeStore == nil)
        #expect(host.contributions.sidebarTabs.isEmpty)
    }

    @Test func templateFilesGoThroughTheFilesystemCapability() async throws {
        let files = MemoryFiles()
        let services = PluginServices(
            readFile: { url in try await files.read(url) },
            writeFile: { data, url in await files.write(data, url) }
        )
        let host = PluginHost(plugins: [TodosPlugin.self], dataRoot: temporaryDirectory(), services: services)
        await host.load()
        let plugin = try #require(host.instance(for: TodosPlugin.manifest.id) as? TodosPlugin)
        let store = try #require(plugin.store)
        await store.load()

        await #expect(throws: TodoTemplate.TemplateError.emptyDirectory) { try await plugin.ensureTemplate() }
        store.updateSettings { $0.storagePath = "/virtual/todos" }
        let url = try await plugin.ensureTemplate()
        #expect(url.path == "/virtual/todos/\(TodoTemplate.fileName)")
        #expect(await files.writes == [url.path])

        try await plugin.importTemplate()
        #expect(store.todos.map(\.title) == ["Example task"])
        #expect(await files.writes == [url.path])

        store.add(title: "Exported", tags: ["io"], scope: .project("p"))
        #expect(try await plugin.exportTemplate() == url)
        #expect(await files.writes == [url.path, url.path])
        let exported = try TodoTemplate.parse(try await files.read(url))
        #expect(exported.map(\.title) == ["Example task", "Exported"])
        #expect(exported.last?.projectID == "p")

        try await host.setEnabled(false, for: TodosPlugin.manifest.id)
        await #expect(throws: TodosPlugin.TemplateAccessError.inactive) { try await plugin.ensureTemplate() }
    }

    @Test func pluginWithoutFileServicesCannotTouchTheTemplate() async throws {
        let host = PluginHost(plugins: [TodosPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        let plugin = try #require(host.instance(for: TodosPlugin.manifest.id) as? TodosPlugin)
        plugin.store?.updateSettings { $0.storagePath = "/virtual/none" }
        await #expect(throws: PluginError.serviceUnavailable(.filesystemRead)) { try await plugin.ensureTemplate() }
        try await host.setEnabled(false, for: TodosPlugin.manifest.id)
    }
}

@Suite struct PomodoroTimerTests {
    let t0 = Date(timeIntervalSince1970: 0)
    let lengths = PomodoroLengths(work: 100, shortBreak: 10, longBreak: 30, cyclesPerLongBreak: 2)

    @Test func startPauseResumeReset() {
        var timer = PomodoroTimer(focusTodoId: "todo-1")
        #expect(timer.remaining(now: t0) == 0)
        timer.start(lengths: lengths, now: t0)
        #expect(timer.phase == .work && timer.status == .running)
        #expect(timer.remaining(now: t0.addingTimeInterval(40)) == 60)
        timer.pause(now: t0.addingTimeInterval(40))
        #expect(timer.status == .paused)
        #expect(timer.remaining(now: t0.addingTimeInterval(500)) == 60)
        #expect(timer.tick(now: t0.addingTimeInterval(500)) == nil)
        timer.resume(now: t0.addingTimeInterval(500))
        #expect(timer.endsAt == t0.addingTimeInterval(560))
        timer.reset()
        #expect(timer.status == .idle && timer.phase == .idle && timer.cyclesCompleted == 0)
        #expect(timer.focusTodoId == "todo-1")
    }

    @Test func phaseTransitionsWithLongBreakCadence() {
        var timer = PomodoroTimer()
        var now = t0
        timer.start(lengths: lengths, now: now)
        #expect(timer.tick(now: now.addingTimeInterval(99)) == nil)
        now = now.addingTimeInterval(100)
        #expect(timer.tick(now: now) == .work)
        #expect(timer.status == .finished && timer.cyclesCompleted == 1)
        timer.start(lengths: lengths, now: now)
        #expect(timer.phase == .shortBreak)
        now = now.addingTimeInterval(10)
        #expect(timer.tick(now: now) == .shortBreak)
        #expect(timer.cyclesCompleted == 1)
        timer.start(lengths: lengths, now: now)
        #expect(timer.phase == .work)
        now = now.addingTimeInterval(100)
        timer.tick(now: now)
        timer.start(lengths: lengths, now: now)
        #expect(timer.phase == .longBreak)
        #expect(timer.remaining(now: now) == 30)
        timer.start(.work, lengths: lengths, now: now)
        #expect(timer.phase == .work)
    }

    @Test func codableSessionSurvivesRelaunch() throws {
        var timer = PomodoroTimer(focusTodoId: "f")
        timer.start(lengths: lengths, now: t0)
        timer.pause(now: t0.addingTimeInterval(25))
        let decoded = try JSONDecoder().decode(PomodoroTimer.self, from: JSONEncoder().encode(timer))
        #expect(decoded == timer)
        #expect(decoded.remaining(now: t0.addingTimeInterval(9_999)) == 75)
    }

    @Test func focusClearsWhenTodoCompletesOrDisappears() {
        var timer = PomodoroTimer(focusTodoId: "a")
        timer.validateFocus(against: [Todo(id: "a", title: "A")])
        #expect(timer.focusTodoId == "a")
        timer.validateFocus(against: [Todo(id: "a", title: "A", done: true)])
        #expect(timer.focusTodoId == nil)
    }
}
