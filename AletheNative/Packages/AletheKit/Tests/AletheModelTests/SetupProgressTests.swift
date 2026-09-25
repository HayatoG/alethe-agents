import Testing
@testable import AletheModel

struct SetupProgressTests {
    @Test func stepsCompleteFromWhatExists() {
        var document = WorkspaceDocument()
        #expect(SetupProgress(document: document, agentsFound: false, marked: nil).count == 0)
        let project = Project(name: "A", folder: "/a")
        document.projects = [project]
        document.ungroupedProjectIDs = [project.id]
        var progress = SetupProgress(document: document, agentsFound: true, marked: ["appearance", "bogus"])
        #expect(progress.done == [.agents, .project, .appearance])
        #expect(!progress.isComplete)
        document.addPane(to: project.id, tab: PaneTab(agent: "shell"))
        progress = SetupProgress(document: document, agentsFound: true, marked: ["appearance"])
        #expect(progress.isComplete)
    }
}
