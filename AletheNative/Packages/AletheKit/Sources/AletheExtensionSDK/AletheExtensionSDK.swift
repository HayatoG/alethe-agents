import Foundation

/// What a third-party ExtensionKit extension links to talk to Alethe (ADR-9, P4-19). Foundation only,
/// so it builds into a sandboxed extension without pulling in any of the app's modules.
public enum AletheExtensionPoint {
    /// Alethe's bundle identifier: the host half of `AppExtensionPoint.Identifier(host:name:)`.
    public static let hostBundleIdentifier = "com.kc1t.alethe.mac"
    /// The point's name: the other half.
    public static let name = "sidebar-tab"
    /// The `PrimitiveAppExtensionScene` id the host shows in the right sidebar.
    public static let sidebarSceneID = "sidebar"
}

/// Metadata the extension reports over XPC before it is enabled. Capabilities are raw strings the
/// host maps strictly (an unknown one rejects the extension).
public struct ExtensionManifestPayload: Codable, Sendable, Equatable {
    public struct Command: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct SidebarTab: Codable, Sendable, Equatable {
        public var title: String
        /// SF Symbol name.
        public var symbol: String

        public init(title: String, symbol: String) {
            self.title = title
            self.symbol = symbol
        }
    }

    public var name: String
    public var version: String
    public var apiMajor: Int
    public var apiMinor: Int
    public var capabilities: [String]
    public var commands: [Command]
    public var sidebarTab: SidebarTab?

    public init(
        name: String,
        version: String,
        apiMajor: Int = 1,
        apiMinor: Int = 0,
        capabilities: [String],
        commands: [Command] = [],
        sidebarTab: SidebarTab? = nil
    ) {
        self.name = name
        self.version = version
        self.apiMajor = apiMajor
        self.apiMinor = apiMinor
        self.capabilities = capabilities
        self.commands = commands
        self.sidebarTab = sidebarTab
    }
}

/// A request from the extension to a host service. Each one needs a declared, granted capability.
public enum HostRequest: Codable, Sendable, Equatable {
    case storageGet(key: String)
    case storageSet(key: String, value: String?)
}

public enum HostResponse: Codable, Sendable, Equatable {
    case value(String?)
    case done
    /// The capability behind the request was not granted (raw `PluginCapability` value).
    case denied(capability: String)
    case failed(String)
}

/// JSON framing for the `Data` carried by the XPC protocols.
public enum ExtensionWire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// Exported by the host on every connection it opens to an extension.
@objc public protocol AletheHostXPC {
    /// `request` is a JSON `HostRequest`; the reply is a JSON `HostResponse`.
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Exported by the extension on its process connection.
@objc public protocol AletheExtensionXPC {
    /// Replies with a JSON `ExtensionManifestPayload`.
    func manifest(reply: @escaping @Sendable (Data) -> Void)
    /// Runs a command listed in the manifest; replies with a short message for the user, or nil.
    func runCommand(_ id: String, reply: @escaping @Sendable (String?) -> Void)
}

extension NSXPCInterface {
    public static func aletheHost() -> NSXPCInterface { NSXPCInterface(with: AletheHostXPC.self) }
    public static func aletheExtension() -> NSXPCInterface { NSXPCInterface(with: AletheExtensionXPC.self) }
}
