import CoreGraphics
import Testing
@testable import AletheDesign

@Suite struct MotionTests {
    @Test func projectionMatchesApplesFormula() {
        // 1000 pt/s with d = 0.998 projects 499 pt forward.
        #expect(abs(Motion.projectedOffset(velocity: 1000) - 499) < 0.001)
        #expect(Motion.projectedOffset(velocity: 0) == 0)
    }

    @Test func rubberBandResistsProgressively() {
        let small = Motion.rubberBand(overshoot: 10, dimension: 300)
        let large = Motion.rubberBand(overshoot: 200, dimension: 300)
        #expect(small < 10 && small > 5)
        #expect(large < 200 * 0.6)
        #expect(Motion.rubberBand(overshoot: -10, dimension: 300) == -small)
    }

    @Test func snapUsesProjectionNotReleasePoint() {
        // Released near 0 but flicked toward 400: lands on 400.
        #expect(Motion.snapTarget(current: 50, velocity: 800, candidates: [0, 400]) == 400)
        #expect(Motion.snapTarget(current: 50, velocity: 0, candidates: [0, 400]) == 0)
    }

    @Test func defaultSpringsAreCriticallyDamped() {
        #expect(Motion.standard.dampingFraction == 1)
        #expect(Motion.quick.dampingFraction == 1)
        #expect(Motion.momentum.dampingFraction < 1)
    }
}

@Suite struct MetricsTests {
    @Test func scaleIsClampedAndApplied() {
        #expect(Metrics(scale: 5).scale == Metrics.maximumScale)
        #expect(Metrics(scale: 0.1).scale == Metrics.minimumScale)
        #expect(Metrics(scale: 1.2).space(.xl) == 16 * 1.2)
        #expect(Metrics(scale: 1.2).size(100) == 120)
    }
}

@Suite struct FontTests {
    @Test func terminalFontIsBundledAndRegisters() {
        #expect(AletheFonts.registerBundledFonts())
        #expect(NSFontManagerHasFamily(AletheFonts.terminalFamily))
    }
}

import AppKit
private func NSFontManagerHasFamily(_ family: String) -> Bool {
    NSFontManager.shared.availableFontFamilies.contains(family)
}
