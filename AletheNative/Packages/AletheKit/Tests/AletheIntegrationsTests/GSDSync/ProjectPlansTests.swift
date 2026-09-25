import Foundation
import Testing
@testable import AletheIntegrations

@Suite struct ProjectPlansTests {
    @Test func noPlansFolderListsNothing() {
        let root = makeCheckout("plans-none")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectPlans.list(root: root, projectID: "p").isEmpty)
    }

    @Test func listsMarkdownPlansNewestFirstWithTitlesAndTerminals() throws {
        let root = makeCheckout("plans")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".alethe/plans/old.md", "intro\n# Old plan\n")
        try writeFile(root, ".alethe/plans/term-1/new.markdown", "no heading\n")
        try writeFile(root, ".alethe/plans/notes.txt", "# not a plan\n")
        let old = root.appending(path: ".alethe/plans/old.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)

        let plans = ProjectPlans.list(root: root, projectID: "p1")
        #expect(plans.map(\.name) == ["new", "old"])
        #expect(plans[0].terminalID == "term-1")
        #expect(plans[0].title == "new")
        #expect(plans[0].relativePath == ".alethe/plans/term-1/new.markdown")
        #expect(plans[1].terminalID == nil)
        #expect(plans[1].title == "Old plan")
        #expect(plans.allSatisfy { $0.projectID == "p1" })
    }
}

@Suite struct PlanningWatchersTests {
    @Test func startCreatesThePlanningFolderAndReusesTheWatcher() throws {
        let root = makeCheckout("watchers")
        defer { try? FileManager.default.removeItem(at: root) }
        let watchers = PlanningWatchers()
        defer { watchers.stopAll() }
        let first = try watchers.start(projectID: "p", root: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".planning").path))
        #expect(try watchers.start(projectID: "p", root: root) === first)
        #expect(watchers.isWatching(projectID: "p", root: root))
        #expect(!watchers.isWatching(projectID: "other", root: root))
        watchers.stop(projectID: "p", root: root)
        #expect(!watchers.isWatching(projectID: "p", root: root))
    }
}
