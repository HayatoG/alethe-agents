import Foundation
import Testing
@testable import AletheModel

/// `.alethe/project.json` read and written in upstream's shape (P5-5).
struct ProjectMarkerTests {
    static let agents: Set<String> = ["claude", "codex", "opencode", "shell"]

    private func upstreamMarker() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "project", withExtension: "json", subdirectory: "Fixtures/Marker"))
        return try Data(contentsOf: url)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "alethe-marker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsAnUpstreamMarker() throws {
        let marker = try #require(ProjectMarker(data: try upstreamMarker()))
        #expect(marker.name == "Storefront")
        #expect(marker.color == .green)
        #expect(marker.autoWorktree == true)
        #expect(marker.worktreeMode == .localCopy)
        #expect(marker.layoutMode == .grid)
        #expect(marker.githubURL == "https://github.com/someone/storefront")
        #expect(marker.agents == ["claude", "shell", "codex"])
    }

    @Test func restoresPanesWithoutMachineLocalState() throws {
        let marker = try #require(ProjectMarker(data: try upstreamMarker()))
        let panes = marker.panes(folder: "/Users/someone/code/storefront", agents: Self.agents)
        #expect(panes.count == 2, "the markdown pane is not a terminal")
        #expect(panes[0].tabs.map(\.agent) == ["claude", "shell"])
        #expect(panes[0].tabs[0].extraArguments == ["--verbose"])
        #expect(panes.allSatisfy { $0.tabs.allSatisfy { $0.sessionID == nil } })
        #expect(panes.allSatisfy { $0.gridID == nil })
        #expect(panes[0].activeTab?.agent == "shell")
    }

    @Test func unknownAgentsAreLeftOut() throws {
        let marker = try #require(ProjectMarker(data: try upstreamMarker()))
        let panes = marker.panes(folder: "/x", agents: ["shell"])
        #expect(panes.flatMap(\.tabs).map(\.agent) == ["shell"])
    }

    @Test func refusesWhatUpstreamRefuses() {
        #expect(ProjectMarker(data: Data(#"{"name":"x"}"#.utf8)) == nil, "no terminals array")
        #expect(ProjectMarker(data: Data(#"{"terminals":[]}"#.utf8)) == nil, "no name")
        #expect(ProjectMarker(data: Data("not json".utf8)) == nil)
    }

    @Test func applyRestoresSettingsOntoANewProject() throws {
        let marker = try #require(ProjectMarker(data: try upstreamMarker()))
        var project = Project(name: "folder", folder: "/Users/someone/code/storefront")
        marker.apply(to: &project, agents: Self.agents)
        #expect(project.name == "Storefront")
        #expect(project.color == .green)
        #expect(project.usesAutoWorktree)
        #expect(project.effectiveWorktreeMode == .localCopy)
        #expect(project.layoutMode == .grid)
        #expect(project.githubURL == "https://github.com/someone/storefront")
        #expect(project.panes.count == 2)
    }

    @Test func roundTripKeepsUpstreamOnlyKeys() throws {
        let original = try upstreamMarker()
        let marker = try #require(ProjectMarker(data: original))
        var project = Project(name: "folder", folder: "/Users/someone/code/storefront")
        marker.apply(to: &project, agents: Self.agents)

        let written = try ProjectMarker.data(for: project, merging: original)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["id"] as? String == "p_upstream1", "the upstream id is kept")
        #expect(object["validationCommands"] as? [String] == ["npm run build"])
        #expect(object["iconUrl"] as? String == "https://example.com/icon.png")
        #expect(object["mode"] as? String == "standard")

        let reread = try #require(ProjectMarker(data: written))
        #expect(reread.name == marker.name)
        #expect(reread.color == marker.color)
        #expect(reread.autoWorktree == marker.autoWorktree)
        #expect(reread.worktreeMode == marker.worktreeMode)
        #expect(reread.layoutMode == marker.layoutMode)
        #expect(reread.githubURL == marker.githubURL)
        #expect(reread.agents == ["claude", "shell", "codex"])
    }

    @Test func writtenMarkerHasUpstreamsShape() throws {
        var project = Project(name: "api", color: .purple, folder: "/work/api")
        project.panes = [Pane(tabs: [PaneTab(agent: "claude", title: "Main")])]
        let object = try #require(try JSONSerialization.jsonObject(with: ProjectMarker.data(for: project)) as? [String: Any])
        #expect(object["name"] as? String == "api")
        #expect(object["color"] as? String == "purple")
        #expect(object["defaultCwd"] as? String == "/work/api")
        #expect(object["groupId"] is NSNull)
        #expect(object["collapsed"] as? Bool == false)
        #expect(object["layoutMode"] as? String == "auto")
        #expect(object["autoWorktree"] == nil, "defaults stay absent, as upstream leaves them undefined")
        #expect(object["worktreeMode"] == nil)
        let terminal = try #require((object["terminals"] as? [[String: Any]])?.first)
        #expect(terminal["kind"] as? String == "terminal")
        let tab = try #require((terminal["tabs"] as? [[String: Any]])?.first)
        #expect(tab["type"] as? String == "claude")
        #expect(tab["name"] as? String == "Main")
        #expect(tab["cwd"] as? String == "/work/api")
        #expect(tab["ptyId"] is NSNull)
        #expect(terminal["activeTabId"] as? String == tab["id"] as? String)
    }

    @Test func writeCreatesTheFolderAndReadFindsIt() throws {
        let folder = try tempFolder()
        let project = Project(name: "here", color: .teal, folder: folder.path)
        try ProjectMarker.write(project)
        let marker = try #require(ProjectMarker.read(folder: folder))
        #expect(marker.name == "here")
        #expect(marker.color == .teal)
        #expect(ProjectMarker.read(folder: try tempFolder()) == nil)
    }

    @Test func writeRefusesAMissingFolder() {
        #expect(throws: (any Error).self) {
            try ProjectMarker.write(Project(name: "gone", folder: "/definitely/not/here"))
        }
    }
}
