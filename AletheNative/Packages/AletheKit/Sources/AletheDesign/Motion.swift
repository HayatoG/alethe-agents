import CoreGraphics
import SwiftUI

/// Motion rules from the plan's interaction guide (§6.1): critically damped springs by default,
/// bounce only after a gesture that carried momentum. No fixed durations on interruptible motion.
public enum Motion {
    public struct SpringSpec: Hashable, Sendable {
        public let response: Double
        public let dampingFraction: Double

        public var animation: Animation {
            .spring(response: response, dampingFraction: dampingFraction)
        }

        /// Core Animation equivalent (for AppKit hosts such as the pane host).
        public var stiffness: Double { pow(2 * .pi / response, 2) }
        public var damping: Double { 4 * .pi * dampingFraction / response }
    }

    public static let standard = SpringSpec(response: 0.35, dampingFraction: 1.0)
    public static let quick = SpringSpec(response: 0.25, dampingFraction: 1.0)
    public static let momentum = SpringSpec(response: 0.35, dampingFraction: 0.8)

    /// Animation respecting Reduce Motion: a short cross-fade-friendly ease instead of a spring.
    public static func animation(_ spec: SpringSpec, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : spec.animation
    }

    /// Where a flick comes to rest: Apple's exponential-decay projection.
    /// - Parameters:
    ///   - velocity: release velocity in points per second.
    ///   - decelerationRate: 0.998 (normal) or 0.99 (fast).
    public static func projectedOffset(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// Progressive resistance past a boundary.
    public static func rubberBand(overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }

    /// Picks the snap point nearest to where the gesture is going, not where it was released.
    public static func snapTarget(current: CGFloat, velocity: CGFloat, candidates: [CGFloat]) -> CGFloat? {
        let projected = current + projectedOffset(velocity: velocity)
        return candidates.min { abs($0 - projected) < abs($1 - projected) }
    }
}
