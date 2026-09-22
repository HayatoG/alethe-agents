import Foundation

/// A typed identifier, stored as a plain string (the Tauri app's ids are nanoid strings, so imported
/// ids keep working).
public struct Identifier<Owner>: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    private static var alphabet: [Character] {
        Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-")
    }

    /// A new random id (21 characters, nanoid alphabet).
    public static func make() -> Identifier {
        var generator = SystemRandomNumberGenerator()
        let alphabet = alphabet
        return Identifier(rawValue: String((0..<21).map { _ in alphabet[Int(generator.next() % 64)] }))
    }
}

public enum ProjectTag {}
public enum GroupTag {}
public enum PaneTag {}
public enum TabTag {}
public enum ProfileTag {}

public typealias ProjectID = Identifier<ProjectTag>
public typealias GroupID = Identifier<GroupTag>
public typealias PaneID = Identifier<PaneTag>
public typealias TabID = Identifier<TabTag>
public typealias ProfileID = Identifier<ProfileTag>
