import Foundation
import Testing
@testable import AletheModel

struct HomeDataTests {
    @Test func greeting() {
        #expect(Greeting(hour: 4) == .evening)
        #expect(Greeting(hour: 5) == .morning)
        #expect(Greeting(hour: 12) == .afternoon)
        #expect(Greeting(hour: 18) == .evening)
    }

    @Test func recentProjectsFollowHistoryThenSidebar() {
        var document = WorkspaceDocument()
        let a = Project(name: "A", folder: "/a"), b = Project(name: "B", folder: "/b"), c = Project(name: "C", folder: "/c")
        document.projects = [a, b, c]
        document.ungroupedProjectIDs = [a.id, b.id, c.id]
        document.openInTab(b.id)
        document.openInTab(c.id)
        document.close(c.id)
        let recent = document.recentProjectIDs()
        #expect(recent.first == c.id)
        #expect(Set(recent) == [a.id, b.id, c.id])
        #expect(recent.last == a.id)
        #expect(document.recentProjectIDs(limit: 1) == [c.id])
    }
}
