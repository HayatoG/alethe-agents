import Foundation
import Testing
@testable import AletheModel

@Suite struct ProjectWorktreeSettingsTests {
    @Test func olderJSONWithoutWorktreeSettingsDecodes() throws {
        let project = Project(name: "api", folder: "/p")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "autoWorktree")
        object.removeValue(forKey: "worktreeMode")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.autoWorktree == nil)
        #expect(decoded.worktreeMode == nil)
        #expect(decoded.usesAutoWorktree == false)
        #expect(decoded.effectiveWorktreeMode == .gitWorktree)
        #expect(decoded.name == "api")
    }

    @Test func worktreeSettingsRoundTrip() throws {
        var project = Project(name: "api", folder: "/p")
        project.autoWorktree = true
        project.worktreeMode = .localCopy
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.usesAutoWorktree)
        #expect(decoded.effectiveWorktreeMode == .localCopy)
    }

    @Test func modeRawValuesMatchUpstream() throws {
        #expect(ProjectWorktreeMode.gitWorktree.rawValue == "gitWorktree")
        #expect(ProjectWorktreeMode.localCopy.rawValue == "localCopy")
    }

    @Test func documentRoundTripKeepsSettings() throws {
        var doc = WorkspaceDocument()
        let id = doc.addProject(name: "api", folder: "/p", color: .blue, in: .ungrouped)
        doc.updateProject(id) {
            $0.autoWorktree = true
            $0.worktreeMode = .gitWorktree
        }
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(doc))
        #expect(decoded.project(id)?.autoWorktree == true)
        #expect(decoded.project(id)?.worktreeMode == .gitWorktree)
    }
}
