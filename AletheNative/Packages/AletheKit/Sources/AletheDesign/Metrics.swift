import CoreGraphics
import SwiftUI

/// Spacing, radius and control sizes. Every metric is multiplied by the UI scale (⌘+/⌘−), which
/// replaces `scaleEffect` zoom: the layout itself grows, so hit-targets stay where they are drawn.
public struct Metrics: Hashable, Sendable {
    public static let minimumScale: CGFloat = 0.8
    public static let maximumScale: CGFloat = 1.5

    public let scale: CGFloat

    public init(scale: CGFloat = 1) {
        self.scale = min(max(scale, Self.minimumScale), Self.maximumScale)
    }

    public enum Space: CGFloat, CaseIterable, Sendable {
        case xxs = 2, xs = 4, s = 6, m = 8, l = 12, xl = 16, xxl = 20, xxxl = 24, huge = 32
    }

    public enum Radius: CGFloat, CaseIterable, Sendable {
        case sm = 4, md = 8, lg = 14
    }

    public func space(_ space: Space) -> CGFloat { space.rawValue * scale }
    public func radius(_ radius: Radius) -> CGFloat { radius.rawValue * scale }
    /// Any fixed size from a design (widths, icon sizes) goes through this.
    public func size(_ points: CGFloat) -> CGFloat { points * scale }
}

extension EnvironmentValues {
    @Entry public var metrics = Metrics()
    @Entry public var theme: Theme = ThemeCatalog.builtin.defaultTheme
}
