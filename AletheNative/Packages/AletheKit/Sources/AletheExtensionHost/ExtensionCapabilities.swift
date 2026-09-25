import Foundation
import AlethePluginKit

/// Pure-Swift model of a third-party ExtensionKit extension, independent of ExtensionFoundation so
/// it is unit-testable (P4-19 spike). The app layer fills it from `AppExtensionIdentity` plus the
/// extension's `AletheExtension` Info.plist dictionary.
public struct ExtensionDescriptor: Hashable, Sendable, Codable {
    /// `AppExtensionIdentity.bundleIdentifier`.
    public var bundleIdentifier: String
    public var localizedName: String
    public var version: String
    /// Raw capability strings the extension declares; unknown ones are rejected, never ignored.
    public var declaredCapabilities: [String]
    public var apiVersion: PluginAPIVersion

    public init(
        bundleIdentifier: String,
        localizedName: String,
        version: String,
        declaredCapabilities: [String],
        apiVersion: PluginAPIVersion = .current
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.version = version
        self.declaredCapabilities = declaredCapabilities
        self.apiVersion = apiVersion
    }
}

public enum ExtensionValidationError: Error, Equatable, Sendable {
    case unknownCapabilities([String])
    case incompatibleAPI(PluginAPIVersion)
    case emptyIdentifier
}

public enum ExtensionCapabilityMapper {
    /// Maps declared strings to `PluginCapability`. Strict: any unknown string fails the whole
    /// extension, so a newer extension cannot silently gain an unreviewed capability.
    public static func capabilities(of descriptor: ExtensionDescriptor) throws -> Set<PluginCapability> {
        var result: Set<PluginCapability> = []
        var unknown: [String] = []
        for raw in descriptor.declaredCapabilities {
            if let cap = PluginCapability(rawValue: raw) { result.insert(cap) } else { unknown.append(raw) }
        }
        if !unknown.isEmpty { throw ExtensionValidationError.unknownCapabilities(unknown.sorted()) }
        return result
    }

    /// Builds the host-side manifest. Third-party extensions start disabled until consent.
    public static func manifest(for descriptor: ExtensionDescriptor) throws -> PluginManifest {
        guard !descriptor.bundleIdentifier.isEmpty else { throw ExtensionValidationError.emptyIdentifier }
        guard descriptor.apiVersion.isCompatible() else {
            throw ExtensionValidationError.incompatibleAPI(descriptor.apiVersion)
        }
        return PluginManifest(
            id: descriptor.bundleIdentifier,
            version: descriptor.version,
            name: descriptor.localizedName,
            capabilities: try capabilities(of: descriptor),
            apiVersion: descriptor.apiVersion,
            enabledByDefault: false
        )
    }
}
