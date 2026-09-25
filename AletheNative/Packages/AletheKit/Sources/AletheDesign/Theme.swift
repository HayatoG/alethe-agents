import AppKit
import SwiftUI

public struct ThemeShadow: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let blur: Double
    public let color: ThemeColor
}

public enum ShadowLevel: String, CaseIterable, Codable, Sendable {
    case sm, md, lg
}

/// Terminal colors handed to the terminal engine (Ghostty config).
public struct TerminalPalette: Hashable, Sendable, Codable {
    public let background: ThemeColor
    public let foreground: ThemeColor
    public let cursor: ThemeColor
    public let selection: ThemeColor
    /// 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright set.
    public let ansi: [ThemeColor]
}

/// A complete theme: every `ThemeToken` resolved (no cascade at runtime).
public struct Theme: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let isLight: Bool
    /// Three colors shown in the theme picker.
    public let swatch: [ThemeColor]
    public let colors: [ThemeToken: ThemeColor]
    public let shadows: [ShadowLevel: ThemeShadow]
    public let terminal: TerminalPalette

    public subscript(token: ThemeToken) -> Color {
        (colors[token] ?? Self.missingTokenColor).color
    }

    /// The token for AppKit layers (borders, backgrounds of hosted NSViews).
    public func nsColor(_ token: ThemeToken) -> NSColor {
        (colors[token] ?? Self.missingTokenColor).nsColor
    }

    public func shadow(_ level: ShadowLevel) -> ThemeShadow {
        shadows[level] ?? ThemeShadow(x: 0, y: 0, blur: 0, color: Self.missingTokenColor)
    }

    /// Validation guarantees every token exists; this only keeps a malformed plugin theme from crashing.
    private static let missingTokenColor = ThemeColor(hex: "#00000000")!

    init(id: String, isLight: Bool, swatch: [ThemeColor], colors: [ThemeToken: ThemeColor],
         shadows: [ShadowLevel: ThemeShadow], terminal: TerminalPalette) {
        self.id = id
        self.isLight = isLight
        self.swatch = swatch
        self.colors = colors
        self.shadows = shadows
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey {
        case id, isLight, swatch, colors, shadows, terminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isLight = try container.decode(Bool.self, forKey: .isLight)
        swatch = try container.decode([ThemeColor].self, forKey: .swatch)
        let rawColors = try container.decode([String: ThemeColor].self, forKey: .colors)
        colors = Dictionary(uniqueKeysWithValues: rawColors.compactMap { key, value in
            ThemeToken(rawValue: key).map { ($0, value) }
        })
        let rawShadows = try container.decode([String: ThemeShadow].self, forKey: .shadows)
        shadows = Dictionary(uniqueKeysWithValues: rawShadows.compactMap { key, value in
            ShadowLevel(rawValue: key).map { ($0, value) }
        })
        terminal = try container.decode(TerminalPalette.self, forKey: .terminal)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isLight, forKey: .isLight)
        try container.encode(swatch, forKey: .swatch)
        try container.encode(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }), forKey: .colors)
        try container.encode(Dictionary(uniqueKeysWithValues: shadows.map { ($0.key.rawValue, $0.value) }), forKey: .shadows)
        try container.encode(terminal, forKey: .terminal)
    }

    /// Problems that make a theme unusable: missing tokens, wrong swatch or ANSI sizes.
    public var validationErrors: [String] {
        var errors: [String] = []
        let missing = ThemeToken.allCases.filter { colors[$0] == nil }
        if !missing.isEmpty { errors.append("missing tokens: \(missing.map(\.rawValue).joined(separator: ", "))") }
        if swatch.count != 3 { errors.append("swatch must have 3 colors") }
        if terminal.ansi.count != 16 { errors.append("terminal palette must have 16 ANSI colors") }
        if ShadowLevel.allCases.contains(where: { shadows[$0] == nil }) { errors.append("missing shadow levels") }
        return errors
    }
}
