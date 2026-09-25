import Foundation
import Testing
@testable import AletheModel

/// Project settings export/import (P5-6).
struct ProjectSettingsFileTests {
    private func project() -> Project {
        var project = Project(name: "Storefront", color: .purple, folder: "/work/storefront")
        project.autoWorktree = true
        project.worktreeMode = .localCopy
        project.layoutMode = .grid
        project.githubURL = "https://github.com/someone/storefront"
        project.panes = [Pane(tabs: [PaneTab(agent: "claude")])]
        return project
    }

    @Test func roundTripRestoresEverySetting() throws {
        let source = project()
        let file = try ProjectSettingsFile(data: ProjectSettingsFile(project: source).data())
        var target = Project(name: "other", folder: "/work/other")
        file.apply(to: &target)
        #expect(target.name == source.name)
        #expect(target.color == source.color)
        #expect(target.autoWorktree == true)
        #expect(target.worktreeMode == .localCopy)
        #expect(target.layout == .grid)
        #expect(target.githubURL == source.githubURL)
        #expect(target.folder == "/work/other", "the folder is not a setting")
        #expect(target.panes.isEmpty, "terminals are not exported")
        #expect(file.changes(to: target).isEmpty)
    }

    @Test func exportLeavesTerminalsOutButStaysUpstreamImportable() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: ProjectSettingsFile(project: project()).data()) as? [String: Any])
        #expect((object["terminals"] as? [Any])?.isEmpty == true)
        #expect(object["name"] as? String == "Storefront")
        #expect(object["githubUrl"] as? String == "https://github.com/someone/storefront")
        #expect(object["defaultCwd"] == nil)
    }

    @Test func defaultsAreExportedExplicitlyAndStoredAbsent() throws {
        let plain = Project(name: "plain", folder: "/p")
        let file = try ProjectSettingsFile(data: ProjectSettingsFile(project: plain).data())
        #expect(file.autoWorktree == false)
        #expect(file.worktreeMode == .gitWorktree)
        #expect(file.layoutMode == .auto)
        var target = project()
        file.apply(to: &target)
        #expect(target.autoWorktree == nil)
        #expect(target.worktreeMode == nil)
        #expect(target.layoutMode == nil)
    }

    @Test func unknownKeysAreIgnoredAndMissingOnesKept() throws {
        let json = #"{"name":"Renamed","terminals":[{"id":"t"}],"iconUrl":"x","validationCommands":["make"],"future":{"a":1}}"#
        let file = try ProjectSettingsFile(data: Data(json.utf8))
        #expect(file == ProjectSettingsFile(name: "Renamed"))
        var target = project()
        file.apply(to: &target)
        #expect(target.name == "Renamed")
        #expect(target.color == .purple)
        #expect(target.worktreeMode == .localCopy)
        #expect(target.panes.count == 1)
    }

    @Test func readsAnUpstreamExport() throws {
        let json = ##"{"id":"p1","name":"Shop","color":"#ef4444","groupId":null,"terminals":[],"layoutMode":"spotlight","collapsed":false,"createdAt":1,"autoWorktree":true}"##
        let file = try ProjectSettingsFile(data: Data(json.utf8))
        #expect(file.color == .red)
        #expect(file.layoutMode == .spotlight)
        #expect(file.autoWorktree == true)
    }

    @Test func listsWhatAnImportChanges() {
        let current = project()
        let file = ProjectSettingsFile(name: "Storefront", color: .green, autoWorktree: false, layoutMode: .auto)
        #expect(file.changes(to: current) == [
            .color(from: .purple, to: .green),
            .autoWorktree(from: true, to: false),
            .layoutMode(from: .grid, to: .auto),
        ])
    }

    @Test func refusesFilesWithoutSettings() {
        #expect(throws: ProjectSettingsFile.Failure.unreadable) { try ProjectSettingsFile(data: Data("[1,2]".utf8)) }
        #expect(throws: ProjectSettingsFile.Failure.unreadable) { try ProjectSettingsFile(data: Data("nope".utf8)) }
        #expect(throws: ProjectSettingsFile.Failure.noSettings) { try ProjectSettingsFile(data: Data(#"{"other":1}"#.utf8)) }
    }

    @Test func suggestedFileNameLikeUpstream() {
        #expect(ProjectSettingsFile.suggestedFileName(for: Project(name: "My App!", folder: "/x")) == "My-App-.alethe-project.json")
    }
}
