import Foundation
import Testing
@testable import AletheGit
@testable import AletheGitControl
@testable import AlethePluginKit

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AletheGitControlTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func entry(_ path: String, kind: GitStatusEntry.Kind = .ordinary,
                   index: GitChange? = nil, worktree: GitChange? = nil) -> GitStatusEntry {
    GitStatusEntry(kind: kind, path: path, originalPath: nil, index: index, worktree: worktree, submodule: nil)
}

@Suite struct GitChangeGroupsTests {
    @Test func splitsConflictsStagedAndUnstaged() {
        let status = GitStatus(branch: GitBranchStatus(head: "main"), entries: [
            entry("both.txt", index: .modified, worktree: .modified),
            entry("staged.txt", index: .added),
            entry("edited.txt", worktree: .deleted),
            entry("new.txt", kind: .untracked),
            entry("clash.txt", kind: .unmerged, index: .unmerged, worktree: .unmerged),
            entry("build.log", kind: .ignored),
        ])
        let groups = GitChangeGroups(status)
        #expect(groups.conflicts.map(\.path) == ["clash.txt"])
        #expect(groups.staged.map(\.path) == ["both.txt", "staged.txt"])
        #expect(groups.unstaged.map(\.path) == ["both.txt", "edited.txt", "new.txt"])
        #expect(!groups.isEmpty)
    }

    @Test func emptyWithoutStatusOrChanges() {
        #expect(GitChangeGroups(nil).isEmpty)
        let ignoredOnly = GitStatus(branch: GitBranchStatus(), entries: [entry("x", kind: .ignored)])
        #expect(GitChangeGroups(ignoredOnly).isEmpty)
    }
}

@Suite struct GitControlPathsTests {
    private let root = URL(filePath: "/nonexistent-alethe/repo", directoryHint: .isDirectory)

    @Test func folderAtRootKeepsThePath() {
        #expect(GitControlPaths.folderRelative("src/a.swift", root: root, folder: root) == "src/a.swift")
    }

    @Test func subfolderStripsItsPrefix() {
        let folder = root.appending(path: "app", directoryHint: .isDirectory)
        #expect(GitControlPaths.folderRelative("app/src/a.swift", root: root, folder: folder) == "src/a.swift")
    }

    @Test func fileOutsideTheSubfolderClimbs() {
        let folder = root.appending(path: "app/ui", directoryHint: .isDirectory)
        #expect(GitControlPaths.folderRelative("docs/readme.md", root: root, folder: folder) == "../../docs/readme.md")
    }
}

@Suite struct GitBranchNameTests {
    @Test func acceptsOrdinaryNames() {
        for name in ["main", "feature/login", "fix-42", "release_1.2", "user/topic/sub"] {
            #expect(GitBranchName.issue(name) == nil, "\(name)")
        }
    }

    @Test func rejectsWhatGitRejects() {
        let invalid = ["-x", "/a", "a/", "a.", "a..b", "a//b", "a@{1}", "@", "a b", "a~1", "a^", "a:b",
                       "a?", "a*", "a[", "a\\b", ".hidden", "a/.b", "a.lock", "a/b.lock/c", "tab\there", "del\u{7F}"]
        for name in invalid {
            #expect(GitBranchName.issue(name) == .invalid, "\(name)")
        }
    }

    @Test func reportsEmptyAndExisting() {
        #expect(GitBranchName.issue("") == .empty)
        #expect(GitBranchName.issue("main", existing: ["dev", "main"]) == .exists)
        #expect(GitBranchName.issue("main2", existing: ["dev", "main"]) == nil)
    }
}

@MainActor
@Suite struct GitControlPluginTests {
    @Test func contributesCommandAndSheetWithGitCapability() async throws {
        #expect(GitControlPlugin.manifest.capabilities == [.git])
        #expect(GitControlPlugin.manifest.hasValidID)
        let host = PluginHost(plugins: [GitControlPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        #expect(host.record(for: GitControlPlugin.manifest.id)?.state == .active)
        let sheet = try #require(host.contributions.sheets.first)
        #expect(sheet.id == GitControlPlugin.sheetID)
        #expect(sheet.viewID == GitControlPlugin.viewID)
        let command = try #require(host.contributions.commands.first)
        #expect(command.id == GitControlPlugin.openCommandID)

        var opened = false
        GitControlPlugin.onOpen = { opened = true }
        command.perform()
        #expect(opened)
        GitControlPlugin.onOpen = nil
    }

    @Test func disablingRemovesTheContributions() async throws {
        let host = PluginHost(plugins: [GitControlPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        try await host.setEnabled(false, for: GitControlPlugin.manifest.id)
        #expect(host.contributions.commands.isEmpty)
        #expect(host.contributions.sheets.isEmpty)
        try await host.setEnabled(true, for: GitControlPlugin.manifest.id)
        #expect(host.contributions.sheets.map(\.id) == [GitControlPlugin.sheetID])
    }
}
