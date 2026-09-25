import Foundation
import AlethePluginKit

/// First-enable consent for a third-party extension. Persisted (Codable) per bundle id.
public struct ExtensionConsentRecord: Hashable, Sendable, Codable {
    public var bundleIdentifier: String
    public var version: String
    public var granted: Set<PluginCapability>
    public var decidedAt: Date

    public init(bundleIdentifier: String, version: String, granted: Set<PluginCapability>, decidedAt: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.granted = granted
        self.decidedAt = decidedAt
    }
}

public enum ExtensionConsentDecision: Equatable, Sendable {
    /// Every requested capability is already granted: enable without prompting.
    case allowed
    /// Show the prompt listing exactly these capabilities (first enable, or an update asking for more).
    case promptRequired(Set<PluginCapability>)
    /// The user denied this extension; stays off until re-enabled from Settings.
    case denied
}

/// Codable store of consent decisions; the app persists it next to the plugin state.
public struct ExtensionConsentLedger: Hashable, Sendable, Codable {
    public private(set) var records: [String: ExtensionConsentRecord]
    public private(set) var denied: Set<String>

    public init() {
        records = [:]
        denied = []
    }

    public func decision(for manifest: PluginManifest) -> ExtensionConsentDecision {
        if denied.contains(manifest.id) { return .denied }
        let granted = records[manifest.id]?.granted ?? []
        let missing = manifest.capabilities.subtracting(granted)
        if records[manifest.id] == nil { return .promptRequired(manifest.capabilities) }
        return missing.isEmpty ? .allowed : .promptRequired(missing)
    }

    /// Records approval of the manifest's full capability set (the prompt is all-or-nothing).
    public mutating func grant(_ manifest: PluginManifest, at date: Date = Date()) {
        denied.remove(manifest.id)
        records[manifest.id] = ExtensionConsentRecord(
            bundleIdentifier: manifest.id,
            version: manifest.version,
            granted: manifest.capabilities,
            decidedAt: date
        )
    }

    public mutating func deny(_ manifest: PluginManifest) {
        records[manifest.id] = nil
        denied.insert(manifest.id)
    }

    /// Clears a decision (extension uninstalled or "reset permissions").
    public mutating func forget(_ bundleIdentifier: String) {
        records[bundleIdentifier] = nil
        denied.remove(bundleIdentifier)
    }

    /// Host-side enforcement for XPC requests: only granted capabilities pass.
    public func isAllowed(_ capability: PluginCapability, for bundleIdentifier: String) -> Bool {
        !denied.contains(bundleIdentifier) && (records[bundleIdentifier]?.granted.contains(capability) ?? false)
    }
}
