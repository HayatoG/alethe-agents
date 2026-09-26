import Foundation
import Security
import Synchronization

/// A secret the app keeps per profile (ADR-1: upstream `keyring` and plaintext files → the Keychain).
/// Raw values are part of the Keychain account name and must never change.
public enum KeychainItem: String, CaseIterable, Codable, Hashable, Sendable {
    /// Spotify app client secret (upstream `preferences.spotifyClientSecret`).
    case spotifyClientSecret
    /// Spotify OAuth tokens as `SpotifyTokens` JSON (upstream `spotify_tokens.json`).
    case spotifyTokens
    /// GitHub personal access token for gist sync (upstream `github_sync.json` `token`).
    case githubToken
    /// 9router endpoint key (upstream `preferences.router9.apiKey`).
    case router9APIKey
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Security.framework call failed; the status is safe to log, the value never is.
    case keychain(OSStatus)
    /// A stored value could not be decoded as the expected type.
    case undecodable(KeychainItem)
}

/// Per-profile secret storage. Values are never logged or written to profile files.
public protocol SecretStore: Sendable {
    func data(for item: KeychainItem, profile: String) throws -> Data?
    func set(_ data: Data, for item: KeychainItem, profile: String) throws
    /// Deleting a missing item is not an error.
    func delete(_ item: KeychainItem, profile: String) throws
}

extension SecretStore {
    public func string(for item: KeychainItem, profile: String) throws -> String? {
        try data(for: item, profile: profile).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An empty string deletes the item.
    public func setString(_ value: String, for item: KeychainItem, profile: String) throws {
        if value.isEmpty {
            try delete(item, profile: profile)
        } else {
            try set(Data(value.utf8), for: item, profile: profile)
        }
    }

    public func value<Value: Decodable>(_ type: Value.Type, for item: KeychainItem, profile: String) throws -> Value? {
        guard let data = try data(for: item, profile: profile) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SecretStoreError.undecodable(item)
        }
    }

    public func setValue<Value: Encodable>(_ value: Value, for item: KeychainItem, profile: String) throws {
        try set(JSONEncoder().encode(value), for: item, profile: profile)
    }

    /// Every item of a profile, for when the profile is deleted.
    public func deleteAll(profile: String) throws {
        for item in KeychainItem.allCases { try delete(item, profile: profile) }
    }
}

/// Generic passwords in the login Keychain: service `com.kc1t.alethe.mac`, account
/// `<profile>/<item>`, this device only and never synchronized.
public struct KeychainStore: SecretStore {
    public static let defaultService = AppIdentity.bundleIdentifier

    public let service: String

    /// Tests pass a throwaway service so they never see the user's items.
    public init(service: String = defaultService) {
        self.service = service
    }

    public static func account(for item: KeychainItem, profile: String) -> String {
        "\(profile)/\(item.rawValue)"
    }

    private func query(_ item: KeychainItem, profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: item, profile: profile),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func data(for item: KeychainItem, profile: String) throws -> Data? {
        var search = query(item, profile: profile)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.keychain(status)
        }
    }

    public func set(_ data: Data, for item: KeychainItem, profile: String) throws {
        let base = query(item, profile: profile)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Alethe (\(item.rawValue))"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public func delete(_ item: KeychainItem, profile: String) throws {
        let status = SecItemDelete(query(item, profile: profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    /// The store a launch uses. Debug launches with a test data root (`-AletheDataRoot`, UI tests)
    /// or `-AletheNoKeychain YES` (ADR-8: unstable dev signing makes the Keychain prompt) get one
    /// process-wide in-memory store; everything else gets the Keychain.
    public static func forLaunch(defaults: UserDefaults = .standard) -> any SecretStore {
        #if DEBUG
        if defaults.string(forKey: "AletheDataRoot") != nil || defaults.bool(forKey: "AletheNoKeychain") {
            return InMemorySecretStore.launchShared
        }
        #endif
        return KeychainStore()
    }
}

/// Secrets kept in memory only: unit tests and UI-test launches.
public final class InMemorySecretStore: SecretStore {
    static let launchShared = InMemorySecretStore()

    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for item: KeychainItem, profile: String) throws -> Data? {
        items.withLock { $0[KeychainStore.account(for: item, profile: profile)] }
    }

    public func set(_ data: Data, for item: KeychainItem, profile: String) throws {
        items.withLock { $0[KeychainStore.account(for: item, profile: profile)] = data }
    }

    public func delete(_ item: KeychainItem, profile: String) throws {
        _ = items.withLock { $0.removeValue(forKey: KeychainStore.account(for: item, profile: profile)) }
    }
}

/// The `spotifyTokens` item (upstream `StoredTokens`). `expiresAt` is stored as epoch seconds, like
/// upstream's `expires_at`.
public struct SpotifyTokens: Codable, Hashable, Sendable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .expiresAt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
    }

    /// Never prints the tokens.
    public var description: String { "SpotifyTokens(expiresAt: \(expiresAt))" }
}
