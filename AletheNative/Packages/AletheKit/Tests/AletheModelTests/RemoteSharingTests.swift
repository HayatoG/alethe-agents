import Foundation
import Testing
@testable import AletheModel

/// What remote control may see (P7-12, upstream `remote/workspace.rs`): only tabs of panes the user
/// shared one by one.
@Suite struct RemoteSharingTests {
    private struct Seeded {
        var doc = WorkspaceDocument()
        var group: GroupID
        var api: ProjectID
        var web: ProjectID
        var sharedPane: PaneID
        var privatePane: PaneID
        var webPane: PaneID
        var first: PaneTab
        var second: PaneTab
    }

    private func seeded() -> Seeded {
        var doc = WorkspaceDocument()
        let group = doc.addGroup(name: "Work")
        let api = doc.addProject(name: "api", folder: "/p/api", in: .group(group))
        let web = doc.addProject(name: "web", folder: "/p/web")
        let first = PaneTab(agent: "claude", sessionID: "s1")
        let second = PaneTab(agent: "shell", workingDirectory: "/p/api/sub")
        let sharedPane = doc.addPane(to: api, tab: first)!
        _ = doc.addTab(second, to: sharedPane)
        let privatePane = doc.addPane(to: api, tab: PaneTab(agent: "codex"))!
        let webPane = doc.addPane(to: web, tab: PaneTab(agent: "shell"))!
        doc.setRemoteShared(sharedPane, true)
        return Seeded(doc: doc, group: group, api: api, web: web, sharedPane: sharedPane, privatePane: privatePane,
                      webPane: webPane, first: first, second: second)
    }

    @Test func onlyTabsOfSharedPanesAreListed() {
        let seed = seeded()

        let shared = seed.doc.remoteSharedTerminals

        #expect(shared.map(\.tab.id) == [seed.first.id, seed.second.id])
        #expect(shared.allSatisfy { $0.paneID == seed.sharedPane && $0.projectID == seed.api })
        #expect(seed.doc.remoteSharedTerminals(in: seed.doc.project(seed.web)!).isEmpty)
    }

    @Test func aTabFolderWinsOverTheProjectFolder() {
        let shared = seeded().doc.remoteSharedTerminals

        #expect(shared.map(\.cwd) == ["/p/api", "/p/api/sub"])
    }

    @Test func aBlankTabFolderFallsBackToTheProject() {
        var seed = seeded()
        seed.doc.updateTab(seed.first.id) { $0.workingDirectory = "  " }

        #expect(seed.doc.remoteSharedTerminals.first?.cwd == "/p/api")
    }

    @Test func panesFromOlderFilesAreNotShared() throws {
        var seed = seeded()
        seed.doc.updatePane(seed.privatePane) { $0.remoteShared = nil }
        seed.doc.updatePane(seed.webPane) { $0.remoteShared = false }

        let data = try JSONEncoder().encode(seed.doc)
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: data)

        #expect(decoded.remoteSharedTerminals.map(\.tab.id) == [seed.first.id, seed.second.id])
    }

    @Test func unsharingRemovesTheTabsAndStoresNothing() {
        var seed = seeded()

        seed.doc.setRemoteShared(seed.sharedPane, false)

        #expect(seed.doc.remoteSharedTerminals.isEmpty)
        #expect(seed.doc.pane(seed.sharedPane)?.pane.remoteShared == nil)
    }

    @Test func aContentPaneCannotBeShared() throws {
        var seed = seeded()
        let added = seed.doc.addPane(to: seed.web, content: .markdown(path: "/p/web/README.md"))
        let markdown = try #require(added)

        seed.doc.setRemoteShared(markdown, true)

        #expect(seed.doc.pane(markdown)?.pane.remoteShared == nil)
        #expect(seed.doc.remoteSharedTerminals.count == 2)
    }

    @Test func theGroupHoldingAProjectIsFound() {
        let seed = seeded()

        #expect(seed.doc.groupID(holding: seed.api) == seed.group)
        #expect(seed.doc.groupID(holding: seed.web) == nil)
    }
}
