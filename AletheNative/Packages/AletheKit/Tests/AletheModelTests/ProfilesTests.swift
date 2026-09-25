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
