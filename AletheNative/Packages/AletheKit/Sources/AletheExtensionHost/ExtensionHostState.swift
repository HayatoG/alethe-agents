@_exported import AletheExtensionSDK
import AletheFoundation
import AlethePluginKit
import Foundation

extension ExtensionDescriptor {
    /// The descriptor of an extension from the manifest it reported over XPC.
    public init(bundleIdentifier: String, payload: ExtensionManifestPayload) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            localizedName: payload.name,
            version: payload.version,
            declaredCapabilities: payload.capabilities,
            apiVersion: PluginAPIVersion(major: payload.apiMajor, minor: payload.apiMinor)
        )
    }
}

/// Result of turning an extension's toggle on.
public enum ExtensionEnableOutcome: Equatable, Sendable {
    case enabled
    /// Show the consent prompt for these capabilities; the extension stays off until approved.
    case needsConsent(Set<PluginCapability>)
}

/// Which third-party extensions are on, plus the consent ledger. Persisted as
/// `extensions.json` in the profile.
public struct ExtensionHostState: Codable, Equatable, Sendable {
    public private(set) var enabled: Set<String>
    public private(set) var ledger: ExtensionConsentLedger

    public init(enabled: Set<String> = [], ledger: ExtensionConsentLedger = ExtensionConsentLedger()) {
        self.enabled = enabled
        self.ledger = ledger
    }

    /// Enables at once when every capability is already granted; otherwise asks for the missing
    /// ones (all of them after a denial).
    public mutating func requestEnable(_ manifest: PluginManifest) -> ExtensionEnableOutcome {
        switch ledger.decision(for: manifest) {
        case .allowed:
            enabled.insert(manifest.id)
            return .enabled
        case .promptRequired(let missing):
            return .needsConsent(missing)
        case .denied:
            ledger.forget(manifest.id)
            return .needsConsent(manifest.capabilities)
        }
    }

    /// The user approved the prompt: grant the full set and enable.
    public mutating func approve(_ manifest: PluginManifest, at date: Date = Date()) {
        ledger.grant(manifest, at: date)
        enabled.insert(manifest.id)
    }

    /// The user declined the prompt: stays off and asks again next time.
    public mutating func decline(_ manifest: PluginManifest) {
        ledger.deny(manifest)
        enabled.remove(manifest.id)
    }

    public mutating func disable(_ bundleIdentifier: String) {
        enabled.remove(bundleIdentifier)
    }

    /// On and with every requested capability granted (an update asking for more is paused until
    /// the user reviews it).
    public func isActive(_ manifest: PluginManifest) -> Bool {
        enabled.contains(manifest.id) && ledger.decision(for: manifest) == .allowed
    }

    /// XPC enforcement: the extension is on and the capability was granted.
    public func isAllowed(_ capability: PluginCapability, for bundleIdentifier: String) -> Bool {
        enabled.contains(bundleIdentifier) && ledger.isAllowed(capability, for: bundleIdentifier)
    }

    /// Reads the state; a missing or unreadable file starts empty.
    public static func load(from url: URL) -> ExtensionHostState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ExtensionHostState.self, from: data) else { return .init() }
        return state
    }

    /// Writes atomically (temporary file + rename).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Serves `HostRequest`s from an extension, checking the capability behind each one first.
public enum ExtensionRequestRouter {
    public static func requiredCapability(for request: HostRequest) -> PluginCapability {
        switch request {
        case .storageGet, .storageSet: .storage
        }
    }

    /// `isAllowed` is `ExtensionHostState.isAllowed` bound to the caller's bundle id.
    public static func handle(
        _ request: HostRequest,
        isAllowed: @Sendable (PluginCapability) -> Bool,
        storage: PluginStorage
    ) async -> HostResponse {
        let capability = requiredCapability(for: request)
        guard isAllowed(capability) else { return .denied(capability: capability.rawValue) }
        switch request {
        case .storageGet(let key):
            guard case .string(let value)? = await storage.value(forKey: key) else { return .value(nil) }
            return .value(value)
        case .storageSet(let key, let value):
            await storage.set(value.map(JSONValue.string), forKey: key)
            return .done
        }
    }

    /// The `plugin-data` file name for an extension: bundle ids may contain upper case letters.
    public static func storageID(for bundleIdentifier: String) -> String {
        "ext." + bundleIdentifier.lowercased()
    }
}
