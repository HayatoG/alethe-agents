import Foundation
import Testing
@testable import AletheModel

@Suite struct ProfilesTests {
    @Test func layoutIsScopedPerProfile() {
        let locations = DataLocations(root: URL(filePath: "/data"))
        let id = ProfileID(rawValue: "abc")
        #expect(locations.profileIndex.path == "/data/profiles.json")
        #expect(locations.workspace(id).path == "/data/profiles/abc/workspace.json")
        #expect(locations.preferences(id).path == "/data/profiles/abc/preferences.json")
        #expect(locations.scrollback(id).path == "/data/profiles/abc/scrollback")
    }

    @Test func profileIdsCannotEscapeTheProfilesFolder() {
        let locations = DataLocations(root: URL(filePath: "/data"))
        let path = locations.profileDirectory(ProfileID(rawValue: "../../etc")).path
        #expect(path.hasPrefix("/data/profiles/"))
        #expect(!path.contains(".."))
    }

    @Test func initialIndexHasTheDefaultProfileActive() {
        let index = ProfileIndexDocument.initial
        #expect(index.activeProfile.id == ProfileIndexDocument.defaultProfileID)
        #expect(index.activeProfile.name == nil)
    }

    @Test func staleActiveIdFallsBackToFirstProfile() {
        var index = ProfileIndexDocument.initial
        let work = index.addProfile(named: "Work")
        index.activeProfileID = work
        #expect(index.activeProfile.name == "Work")
        index.activeProfileID = ProfileID(rawValue: "gone")
        #expect(index.activeProfile.id == ProfileIndexDocument.defaultProfileID)
    }

    @MainActor @Test func profileFilesAreIndependent() async throws {
        let locations = DataLocations(root: FileManager.default.temporaryDirectory.appending(path: "alethe-\(UUID().uuidString)"))
        let a = ProfileID(rawValue: "a"), b = ProfileID(rawValue: "b")
        let first = await WorkspaceModel.load(from: locations.workspace(a))
        first.update { _ = $0.addProject(name: "Only in A", folder: "/a") }
        await first.flush()
        let other = await WorkspaceModel.load(from: locations.workspace(b))
        #expect(other.document.projects.isEmpty)
        let again = await WorkspaceModel.load(from: locations.workspace(a))
        #expect(again.document.projects.map(\.name) == ["Only in A"])
    }
}

/// New Terminal Like Last (P3-4).
@Suite struct TerminalCreationTests {
    @Test func repeatsTheRecordedTab() {
        let creation = TerminalCreation(agent: "codex", folder: "/tmp/x", unrestricted: true, extraArguments: ["--model", "o3"])
        let tab = creation.tab()
        #expect(tab.agent == "codex" && tab.workingDirectory == "/tmp/x" && tab.unrestricted && tab.extraArguments == ["--model", "o3"])
    }

    @Test func olderPreferencesDecodeWithoutIt() throws {
        let json = #"{"schemaVersion":1,"themeID":"elite-indigo","uiScale":1,"alwaysStartUnrestricted":false}"#
        let preferences = try JSONDecoder().decode(PreferencesDocument.self, from: Data(json.utf8))
        #expect(preferences.lastTerminalCreation == nil)
    }
}

/// Profile index operations and profile folders (P5-9).
@Suite struct ProfileOperationsTests {
    private let defaultName = "Default"

    @Test func namesAreNormalized() {
        #expect(ProfileIndexDocument.normalizedName("  Work  ") == "Work")
        #expect(ProfileIndexDocument.normalizedName("Side\n\tproject   two") == "Side project two")
        #expect(ProfileIndexDocument.normalizedName("   ") == nil)
        #expect(ProfileIndexDocument.normalizedName("") == nil)
        #expect(ProfileIndexDocument.normalizedName("a\u{0007}b") == "ab")
        let long = String(repeating: "x", count: 100)
        #expect(ProfileIndexDocument.normalizedName(long)?.count == ProfileIndexDocument.maxNameLength)
    }

    @Test func createRefusesEmptyAndTakenNames() throws {
        var index = ProfileIndexDocument.initial
        let work = try index.createProfile(named: " Work ", defaultName: defaultName)
        #expect(index.profile(work)?.name == "Work")
        #expect(index.profile(work)?.lastUsedAt != nil)
        #expect(throws: ProfileError.nameRequired) { try index.createProfile(named: "  ", defaultName: defaultName) }
        #expect(throws: ProfileError.nameExists) { try index.createProfile(named: "work", defaultName: defaultName) }
        // The unnamed default profile holds its localized name.
        #expect(throws: ProfileError.nameExists) { try index.createProfile(named: "DEFAULT", defaultName: defaultName) }
        #expect(index.profiles.count == 2)
    }

    @Test func renameKeepsItsOwnNameAndRefusesOthers() throws {
        var index = ProfileIndexDocument.initial
        let work = try index.createProfile(named: "Work", defaultName: defaultName)
        try index.renameProfile(work, to: "WORK", defaultName: defaultName)
        #expect(index.profile(work)?.name == "WORK")
        #expect(throws: ProfileError.nameExists) {
            try index.renameProfile(work, to: "default", defaultName: defaultName)
        }
        try index.renameProfile(ProfileIndexDocument.defaultProfileID, to: "Personal", defaultName: defaultName)
        #expect(index.activeProfile.name == "Personal")
        #expect(throws: ProfileError.notFound) {
            try index.renameProfile(ProfileID(rawValue: "gone"), to: "X", defaultName: defaultName)
        }
    }

    @Test func removeNeverTakesTheActiveOrTheLastProfile() throws {
        var index = ProfileIndexDocument.initial
        #expect(throws: ProfileError.activeProfile) { try index.removeProfile(ProfileIndexDocument.defaultProfileID) }
        let work = try index.createProfile(named: "Work", defaultName: defaultName)
        try index.activate(work)
        #expect(throws: ProfileError.activeProfile) { try index.removeProfile(work) }
        try index.removeProfile(ProfileIndexDocument.defaultProfileID)
        #expect(index.profiles.map(\.id) == [work])
        #expect(throws: ProfileError.notFound) { try index.removeProfile(ProfileIndexDocument.defaultProfileID) }
    }

    @Test func lastProfileIsRefusedEvenWhenStale() throws {
        var index = ProfileIndexDocument.initial
        index.activeProfileID = ProfileID(rawValue: "gone")
        // A stale active id falls back to the only profile, which stays.
        #expect(throws: ProfileError.activeProfile) { try index.removeProfile(ProfileIndexDocument.defaultProfileID) }
    }

    @Test func activateStampsLastUse() throws {
        var index = ProfileIndexDocument.initial
        let work = try index.createProfile(named: "Work", defaultName: defaultName, now: Date(timeIntervalSince1970: 10))
        try index.activate(work, now: Date(timeIntervalSince1970: 50))
        #expect(index.activeProfileID == work)
        #expect(index.profile(work)?.lastUsedAt == Date(timeIntervalSince1970: 50))
        #expect(throws: ProfileError.notFound) { try index.activate(ProfileID(rawValue: "gone")) }
    }

    @Test func orderPutsTheActiveFirstThenRecentThenName() throws {
        var index = ProfileIndexDocument.initial
        let b = try index.createProfile(named: "Beta", defaultName: defaultName, now: Date(timeIntervalSince1970: 100))
        let a = try index.createProfile(named: "Alpha", defaultName: defaultName, now: Date(timeIntervalSince1970: 100))
        let recent = try index.createProfile(named: "Recent", defaultName: defaultName, now: Date(timeIntervalSince1970: 200))
        #expect(index.ordered(defaultName: defaultName).map(\.id) == [ProfileIndexDocument.defaultProfileID, recent, a, b])
        try index.activate(b, now: Date(timeIntervalSince1970: 300))
        #expect(index.ordered(defaultName: defaultName).first?.id == b)
    }

    @Test func duplicateNamesAreFree() throws {
        var index = ProfileIndexDocument.initial
        let work = try index.createProfile(named: "Work", defaultName: defaultName)
        #expect(index.duplicateName(for: work, format: "%@ copy", defaultName: defaultName) == "Work copy")
        try index.createProfile(named: "Work copy", defaultName: defaultName)
        #expect(index.duplicateName(for: work, format: "%@ copy", defaultName: defaultName) == "Work copy 2")
        #expect(index.duplicateName(for: ProfileIndexDocument.defaultProfileID, format: "%@ copy", defaultName: defaultName) == "Default copy")
    }

    @Test func olderIndexDecodesWithoutLastUse() throws {
        let json = #"{"schemaVersion":1,"activeProfileID":"default","profiles":[{"id":"default","createdAt":0}]}"#
        let index = try JSONDecoder().decode(ProfileIndexDocument.self, from: Data(json.utf8))
        #expect(index.activeProfile.lastUsedAt == nil)
    }

    @Test func runtimeFilesAreRecognized() {
        #expect(ProfileFiles.isRuntimeFile(relativePath: "workspace.json.tmp"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "spawn.log"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "EBWebView/Default/LOCK"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "ebwebview"))
        #expect(ProfileFiles.isRuntimeFile(relativePath: "scrollback/.DS_Store"))
        #expect(!ProfileFiles.isRuntimeFile(relativePath: "scrollback/tab.bin"))
        #expect(!ProfileFiles.isRuntimeFile(relativePath: "workspace.json"))
    }

    @Test func copyLeavesRuntimeFilesAndCountsTerminals() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "alethe-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(root: root)
        let source = ProfileID(rawValue: "a"), copy = ProfileID(rawValue: "b")
        let folder = locations.profileDirectory(source)
        try FileManager.default.createDirectory(at: locations.scrollback(source), withIntermediateDirectories: true)
        let workspace = #"{"projects":[{"panes":[{"tabs":[{},{}]},{"tabs":[]}]},{"panes":[{"tabs":[{}]}]}]}"#
        try Data(workspace.utf8).write(to: locations.workspace(source))
        try Data("x".utf8).write(to: locations.scrollback(source).appending(path: "t.bin"))
        try Data("x".utf8).write(to: folder.appending(path: "preferences.json.tmp"))
        try FileManager.default.createDirectory(at: folder.appending(path: "EBWebView"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "EBWebView/LOCK"))

        try ProfileFiles.copyProfileFolder(from: folder, to: locations.profileDirectory(copy))
        let copied = locations.profileDirectory(copy)
        #expect(FileManager.default.fileExists(atPath: locations.workspace(copy).path))
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "scrollback/t.bin").path))
        #expect(!FileManager.default.fileExists(atPath: copied.appending(path: "preferences.json.tmp").path))
        #expect(!FileManager.default.fileExists(atPath: copied.appending(path: "EBWebView").path))

        let summary = ProfileFiles.summary(of: copy, in: locations)
        #expect(summary.projects == 2 && summary.terminals == 3)
        #expect(summary.bytes > 0)
        #expect(ProfileFiles.summary(of: ProfileID(rawValue: "missing"), in: locations) == ProfileSummary())
    }
}
