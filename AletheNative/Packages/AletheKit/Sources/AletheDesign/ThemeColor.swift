import AppKit
import SwiftUI

/// An sRGB color stored as `#RRGGBBAA`. The only place in the app allowed to build colors from
/// channel values — everything else reads semantic tokens from `Theme`.
public struct ThemeColor: Hashable, Sendable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        if digits.count == 6 { digits += "ff" }
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 24) & 0xff) / 255
        green = Double((value >> 16) & 0xff) / 255
        blue = Double((value >> 8) & 0xff) / 255
        alpha = Double(value & 0xff) / 255
    }

    public var hex: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// WCAG relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two opaque colors.
    public func contrastRatio(against other: ThemeColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ThemeColor(hex: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid color \(raw)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
