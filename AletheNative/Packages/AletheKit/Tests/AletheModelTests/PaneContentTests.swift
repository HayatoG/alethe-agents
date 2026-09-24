import AletheFoundation
import Foundation
import Testing
@testable import AletheModel

@Suite struct PaneContentTests {
    @Test func everyKindRoundTrips() throws {
        let contents: [PaneContent] = [
            .terminal, .markdown(path: "/p/README.md"), .image(path: "/p/a.png"), .video(path: "/p/v.mov"),
            .diff(path: nil), .diff(path: "src/a.swift"), .web(url: "http://localhost:3000"),
        ]
        for content in contents {
            let data = try JSONEncoder().encode(content)
            #expect(try JSONDecoder().decode(PaneContent.self, from: data) == content)
        }
        let terminal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PaneContent.terminal)) as? [String: String]
        #expect(terminal == ["kind": "terminal"])
    }

    @Test func version1WorkspaceMigratesEveryPaneToATerminal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace.json")
        let tab = TabID.make().rawValue, pane = PaneID.make().rawValue, project = ProjectID.make().rawValue
        let v1 = """
        {"schemaVersion":1,"groups":[],"ungroupedProjectIDs":["\(project)"],
         "projects":[{"id":"\(project)","name":"a","color":"blue","folder":"/a","createdAt":"2026-09-01T12:00:00Z",
           "panes":[{"id":"\(pane)","activeTabID":"\(tab)","laneVisible":true,
             "tabs":[{"id":"\(tab)","agent":"shell","unrestricted":false,"extraArguments":[],"createdAt":"2026-09-01T12:00:00Z"}]}]}],
         "workspace":{"openProjectIDs":[],"containerWeights":[],"gridWeights":{}}}
        """
        try Data(v1.utf8).write(to: url)
        let (document, outcome) = try await DocumentStore<WorkspaceDocument>(url: url).load()
        guard case .migrated(from: 1, _) = outcome else {
            Issue.record("expected a migration from v1, got \(outcome)")
            return
        }
        let migrated = try #require(document.projects.first?.panes.first)
        #expect(migrated.content == .terminal)
        #expect(migrated.tabs.map(\.id.rawValue) == [tab])
        #expect(migrated.laneVisible == true)
        #expect(document.schemaVersion == 2)
    }

    @Test func contentPanesHaveNoTabsAndRefuseThem() {
        var doc = WorkspaceDocument()
        let project = doc.addProject(name: "a", folder: "/a")
        #expect(doc.addPane(to: project, content: .terminal) == nil, "terminals are added with a tab")
        let pane = doc.addPane(to: project, content: .markdown(path: "/a/README.md"))
        let id = try? #require(pane)
        #expect(doc.workspace.focusedPaneID == pane)
        #expect(doc.workspace.openProjectIDs == [project])
        let added = id.map { doc.addTab(PaneTab(agent: "shell"), to: $0) } ?? true
        #expect(!added)
        #expect(doc.pane(pane!)?.pane.tabs.isEmpty == true)
        #expect(doc.pane(pane!)?.pane.isLaneVisible == false)
        #expect(Pane(content: .web(url: "x"), tabs: [PaneTab(agent: "shell")]).tabs.isEmpty)
    }
}

@Suite struct PaneContentForFileTests {
    @Test func classifiesByExtensionLikeUpstream() {
        #expect(PaneContent.forFile("/p/clip.MOV") == .video(path: "/p/clip.MOV"))
        #expect(PaneContent.forFile("/p/shot.png") == .image(path: "/p/shot.png"))
        #expect(PaneContent.forFile("/p/logo.svg") == .image(path: "/p/logo.svg"))
        #expect(PaneContent.forFile("/p/README.md") == .markdown(path: "/p/README.md"))
        #expect(PaneContent.forFile("/p/main.swift") == nil)
        #expect(PaneContent.forFile("/p/noext") == nil)
    }

    @Test func dropsLineAndColumnSuffixes() {
        #expect(PaneContent.forFile(" /p/docs/plan.md:12:4 ") == .markdown(path: "/p/docs/plan.md"))
        #expect(PaneContent.forFile("/p/a.png:3") == .image(path: "/p/a.png"))
        #expect(PaneContent.markdown(path: "/x.md").filePath == "/x.md")
        #expect(PaneContent.terminal.filePath == nil)
    }
}
