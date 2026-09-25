import Foundation
import Testing
@testable import AletheModel

/// Feature toggles (P5-3): upstream `normalizeEnabledFeatures` defaults and the stored map.
@Suite struct FeaturesTests {
    @Test func defaultsMatchUpstream() {
        let on = Feature.allCases.filter(Features.defaults.isOn)
        #expect(on == [.browser, .graphify, .mcp, .prs])
        #expect(Feature.allCases.filter(\.isSecondary) == [.graphify, .gsdSync, .aiMemory])
    }

    @Test func missingKeysUseTheDefault() {
        let features = Features(["prs": false, "aiMemory": true])
        #expect(!features.isOn(.prs) && features.isOn(.aiMemory))
        #expect(features.isOn(.browser) && !features.isOn(.playwright))
    }

    @Test func decodingWithoutTheKeyGivesTheDefaults() throws {
        let json = #"{"schemaVersion":1,"themeID":"nord","uiScale":1,"alwaysStartUnrestricted":false}"#
        let preferences = try JSONDecoder().decode(PreferencesDocument.self, from: Data(json.utf8))
        #expect(preferences.enabledFeatures == nil)
        #expect(preferences.features == .defaults)
    }

    @Test func settingAFeatureKeepsUnknownKeys() throws {
        var preferences = PreferencesDocument()
        preferences.enabledFeatures = ["todos": true]
        preferences.features.set(.prs, on: false)
        #expect(preferences.enabledFeatures == ["todos": true, "prs": false])

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(PreferencesDocument.self, from: data)
        #expect(decoded.enabledFeatures == ["todos": true, "prs": false])
        #expect(!decoded.features.isOn(.prs))
    }

    @Test func emptyChoicesAreNotStored() {
        var preferences = PreferencesDocument()
        preferences.features = Features()
        #expect(preferences.enabledFeatures == nil)
    }
}
