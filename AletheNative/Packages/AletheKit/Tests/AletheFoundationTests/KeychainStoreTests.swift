import Foundation
import Testing
@testable import AletheFoundation

/// The per-profile secret store (P7-1). The Keychain case uses a throwaway service, so the user's
/// own items are never read or written.
@Suite struct KeychainStoreTests {
    private func roundTrip(_ store: any SecretStore) throws {
        let profile = "test-\(UUID().uuidString)"
        defer { try? store.deleteAll(profile: profile) }
        #expect(try store.data(for: .githubToken, profile: profile) == nil)

        try store.setString("first", for: .githubToken, profile: profile)
        try store.setString("second", for: .githubToken, profile: profile)
        #expect(try store.string(for: .githubToken, profile: profile) == "second", "a second set updates")
        #expect(try store.string(for: .githubToken, profile: "other-\(profile)") == nil, "profiles are separate")
        #expect(try store.string(for: .router9APIKey, profile: profile) == nil, "items are separate")

        let tokens = SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_767_225_600))
        try store.setValue(tokens, for: .spotifyTokens, profile: profile)
        #expect(try store.value(SpotifyTokens.self, for: .spotifyTokens, profile: profile) == tokens)

        try store.setString("", for: .githubToken, profile: profile)
        #expect(try store.data(for: .githubToken, profile: profile) == nil, "an empty string deletes")
        try store.delete(.githubToken, profile: profile)

        try store.deleteAll(profile: profile)
        #expect(try store.data(for: .spotifyTokens, profile: profile) == nil)
    }

    @Test func inMemoryRoundTrip() throws {
        try roundTrip(InMemorySecretStore())
    }

    @Test func keychainRoundTripInAThrowawayService() throws {
        let store = KeychainStore(service: "com.kc1t.alethe.mac.tests.\(UUID().uuidString)")
        #expect(store.service != KeychainStore.defaultService)
        try roundTrip(store)
    }

    @Test func accountsAreProfileAndItem() {
        #expect(KeychainStore.account(for: .router9APIKey, profile: "default") == "default/router9APIKey")
        #expect(KeychainStore.defaultService == "com.kc1t.alethe.mac")
        #expect(Set(KeychainItem.allCases.map(\.rawValue))
            == ["spotifyClientSecret", "spotifyTokens", "githubToken", "router9APIKey"])
    }

    @Test func undecodableValueThrows() throws {
        let store = InMemorySecretStore()
        try store.setString("not json", for: .spotifyTokens, profile: "p")
        #expect(throws: SecretStoreError.undecodable(.spotifyTokens)) {
            try store.value(SpotifyTokens.self, for: .spotifyTokens, profile: "p")
        }
    }

    @Test func spotifyTokensStoreEpochSecondsAndNeverPrintTokens() throws {
        let tokens = SpotifyTokens(accessToken: "ACCESS-SECRET", refreshToken: "REFRESH-SECRET",
                                   expiresAt: Date(timeIntervalSince1970: 1_767_225_600))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens)) as? [String: Any])
        #expect(object["expiresAt"] as? Double == 1_767_225_600)
        #expect(!String(describing: tokens).contains("SECRET"))
        #expect(!"\(tokens)".contains("SECRET"))
    }
}
