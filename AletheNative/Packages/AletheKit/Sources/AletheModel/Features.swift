import Foundation

/// An optional module the user turns on or off in Settings › Features (upstream `lib/features.ts`).
/// Each module's surfaces check `Features.isOn(_:)` before showing.
public enum Feature: String, CaseIterable, Codable, Hashable, Sendable {
    case browser, graphify, mcp, playwright, orchestrator, gsdSync, aiMemory, prs

    /// Upstream `normalizeEnabledFeatures`: the opt-in ones start processes, spawn workers or poll.
    public var isOnByDefault: Bool {
        switch self {
        case .browser, .graphify, .mcp, .prs: true
        case .playwright, .orchestrator, .gsdSync, .aiMemory: false
        }
    }

    /// Kept under “Show more” until the user goes looking for it (upstream `secondary`).
    public var isSecondary: Bool {
        switch self {
        case .graphify, .gsdSync, .aiMemory: true
        case .browser, .mcp, .playwright, .orchestrator, .prs: false
        }
    }
}

/// The user's feature choices over the defaults. Stored as upstream's `enabledFeatures` map, so keys
/// this version does not know (upstream's legacy `git`, `todos`) survive a round-trip.
public struct Features: Hashable, Sendable {
    public private(set) var stored: [String: Bool]

    public static let defaults = Features()

    public init(_ stored: [String: Bool]? = nil) {
        self.stored = stored ?? [:]
    }

    public func isOn(_ feature: Feature) -> Bool {
        stored[feature.rawValue] ?? feature.isOnByDefault
    }

    public mutating func set(_ feature: Feature, on: Bool) {
        stored[feature.rawValue] = on
    }

    /// The features that are on, in declaration order.
    public var enabled: [Feature] { Feature.allCases.filter(isOn) }
}

extension PreferencesDocument {
    /// `enabledFeatures` resolved over the defaults; nil and a missing key both mean the default.
    public var features: Features {
        get { Features(enabledFeatures) }
        set { enabledFeatures = newValue.stored.isEmpty ? nil : newValue.stored }
    }
}
