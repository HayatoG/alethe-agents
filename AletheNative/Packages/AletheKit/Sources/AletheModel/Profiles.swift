import AletheFoundation
import Foundation

public struct ProfileEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: ProfileID
    /// nil for the built-in default profile, whose name is localized by the UI.
    public var name: String?
    public var createdAt: Date

    public init(id: ProfileID, name: String?, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// `profiles.json` at the data root: which profiles exist and which one is active.
public struct ProfileIndexDocument: VersionedDocument, Hashable {
    public static let currentVersion = 1
    public static let migrations: [Int: @Sendable (inout JSONObject) throws -> Void] = [:]
    public static let defaultProfileID = ProfileID(rawValue: "default")
    public static let initial = ProfileIndexDocument(
        profiles: [ProfileEntry(id: defaultProfileID, name: nil, createdAt: Date(timeIntervalSince1970: 0))],
        activeProfileID: defaultProfileID
    )

    public var schemaVersion: Int
    public var profiles: [ProfileEntry]
    public var activeProfileID: ProfileID

    public init(schemaVersion: Int = currentVersion, profiles: [ProfileEntry], activeProfileID: ProfileID) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// The active profile, falling back to the first one when the stored id is stale.
    public var activeProfile: ProfileEntry {
        profiles.first { $0.id == activeProfileID } ?? profiles.first ?? Self.initial.profiles[0]
    }

    @discardableResult
    public mutating func addProfile(named name: String) -> ProfileID {
        let entry = ProfileEntry(id: .make(), name: name)
        profiles.append(entry)
        return entry.id
    }
}

/// Where everything lives on disk:
///
///     <root>/profiles.json
///     <root>/profiles/<profile id>/workspace.json
///     <root>/profiles/<profile id>/preferences.json
///     <root>/profiles/<profile id>/prompt-history.json
///     <root>/profiles/<profile id>/scrollback/<tab id>.bin
///
/// `root` is `~/Library/Application Support/com.kc1t.alethe.mac` in the app and a temporary
/// directory in tests.
public struct DataLocations: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func application() throws -> DataLocations {
        DataLocations(root: try AppIdentity.applicationSupportDirectory())
    }

    public var profileIndex: URL { root.appending(path: "profiles.json") }

    public func profileDirectory(_ id: ProfileID) -> URL {
        root.appending(path: "profiles", directoryHint: .isDirectory)
            .appending(path: Self.safeComponent(id.rawValue), directoryHint: .isDirectory)
    }

    public func workspace(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: "workspace.json") }
    public func preferences(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: "preferences.json") }
    public func promptHistory(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: "prompt-history.json") }
    /// Handoff capsules for agents to read (P3-12).
    public func activityStats(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: "activity-stats.json") }
    public func handoffs(_ id: ProfileID) -> URL { profileDirectory(id).appending(path: "handoffs", directoryHint: .isDirectory) }

    public func scrollback(_ id: ProfileID) -> URL {
        profileDirectory(id).appending(path: "scrollback", directoryHint: .isDirectory)
    }

    /// Profile ids become folder names; anything that could escape the profiles folder is replaced.
    static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }
}
