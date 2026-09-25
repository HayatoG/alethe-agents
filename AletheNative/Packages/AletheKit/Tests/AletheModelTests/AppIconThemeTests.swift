import Foundation
import Testing
@testable import AletheModel

/// App icon themes (P5-12): upstream's four ids and `normalizeAppIconTheme`.
@Suite struct AppIconThemeTests {
    @Test func upstreamIdsAndDefault() {
        #expect(AppIconTheme.allCases.map(\.rawValue) == ["elite-original", "elite-pure-black", "elite-indigo", "elite-blush"])
        #expect(PreferencesDocument().iconTheme == .eliteIndigo)
    }

    @Test func unknownValuesFallBackToTheDefault() {
        #expect(AppIconTheme(normalizing: "dracula") == .eliteIndigo)
        #expect(AppIconTheme(normalizing: nil) == .eliteIndigo)
        #expect(AppIconTheme(normalizing: "elite-blush") == .eliteBlush)
    }

    @Test func choiceIsStoredAndTheDefaultIsNot() throws {
        var preferences = PreferencesDocument()
        preferences.iconTheme = .elitePureBlack
        #expect(preferences.appIconTheme == "elite-pure-black")
        let decoded = try JSONDecoder().decode(PreferencesDocument.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.iconTheme == .elitePureBlack)
        preferences.iconTheme = .eliteIndigo
        #expect(preferences.appIconTheme == nil)
    }

    @Test func decodingWithoutTheKeyGivesTheDefault() throws {
        let json = #"{"schemaVersion":1,"themeID":"nord","uiScale":1,"alwaysStartUnrestricted":false}"#
        let preferences = try JSONDecoder().decode(PreferencesDocument.self, from: Data(json.utf8))
        #expect(preferences.iconTheme == .default)
    }

    @Test func assetNames() {
        #expect(AppIconTheme.eliteBlush.assetName == "AppIcon-elite-blush")
    }
}
