import Foundation
import Testing
@testable import AletheModel

@Suite struct ProjectGraphifyTests {
    @Test func olderJSONWithoutTheFlagIsOff() throws {
        let project = Project(name: "api", folder: "/p")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "graphifyEnabled")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.graphifyEnabled == nil && !decoded.usesGraphify)
    }

    @Test func flagRoundTrips() throws {
        var project = Project(name: "api", folder: "/p")
        project.graphifyEnabled = true
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded == project && decoded.usesGraphify)
    }

    @Test func commandPreferenceRoundTrips() throws {
        var preferences = PreferencesDocument()
        #expect(preferences.graphifyCommand == nil)
        preferences.graphifyCommand = "~/bin/graphify"
        let decoded = try JSONDecoder().decode(PreferencesDocument.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.graphifyCommand == "~/bin/graphify")
    }
}
