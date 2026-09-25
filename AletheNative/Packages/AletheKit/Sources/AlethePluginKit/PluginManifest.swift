import Foundation

/// Version of the plugin API (ADR-9). A plugin built against another major version is not loaded;
/// minor versions add API without breaking older plugins.
public struct PluginAPIVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    /// The version this host implements.
    public static let current = PluginAPIVersion(major: 1, minor: 0)

    /// True when a plugin declaring `self` can run on a host implementing `host`.
    public func isCompatible(withHost host: PluginAPIVersion = .current) -> Bool {
        major == host.major && minor <= host.minor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// A host service a plugin must declare before using it. The context refuses any undeclared one.
public enum PluginCapability: String, Hashable, Sendable, Codable, CaseIterable {
    case git
    case filesystemRead
    case filesystemWrite
    case terminalInput
    case network
    case storage
}

public struct PluginManifest: Hashable, Sendable, Codable {
    /// Reverse-DNS style id (`com.alethe.todos`); also names the plugin's storage file.
    public var id: String
    public var version: String
    public var name: String
    public var capabilities: Set<PluginCapability>
    public var apiVersion: PluginAPIVersion
    /// Whether the plugin starts enabled before the user has toggled it.
    public var enabledByDefault: Bool

    public init(
        id: String,
        version: String,
        name: String,
        capabilities: Set<PluginCapability> = [],
        apiVersion: PluginAPIVersion = .current,
        enabledByDefault: Bool = true
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.capabilities = capabilities
        self.apiVersion = apiVersion
        self.enabledByDefault = enabledByDefault
    }

    /// Lowercase letters, digits, `.`, `-` and `_`, starting with a letter or digit, so the id is
    /// safe as a file name.
    public var hasValidID: Bool {
        guard let first = id.unicodeScalars.first, id.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return alphanumeric.contains(first) && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// A plugin: built-ins are listed statically in an array of plugin types handed to `PluginHost`.
@MainActor
public protocol AlethePlugin: AnyObject {
    static var manifest: PluginManifest { get }
    init()
    /// Registers contributions through `context`. Throwing marks the plugin failed; nothing it
    /// registered is kept and the other plugins still load.
    func activate(context: PluginContext) throws
    /// Called when the plugin is disabled or the host shuts down.
    func deactivate()
}

extension AlethePlugin {
    public func deactivate() {}
}

public enum PluginError: Error, Equatable, Sendable {
    case undeclaredCapability(PluginCapability, pluginID: String)
    case incompatibleAPI(required: PluginAPIVersion, host: PluginAPIVersion)
    case invalidID(String)
    case duplicatePlugin(String)
    case duplicateContribution(kind: String, id: String)
    /// The host did not provide the service behind a declared capability.
    case serviceUnavailable(PluginCapability)
    case inactive(pluginID: String)
    case unknownPlugin(String)
}
