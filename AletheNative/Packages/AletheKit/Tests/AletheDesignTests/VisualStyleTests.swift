import Testing
@testable import AletheDesign

/// Clean visual style and reduced motion (P2-27).
@Suite struct VisualStyleTests {
    private var theme: Theme { ThemeCatalog.builtin.defaultTheme }

    @Test func normalLeavesTheThemeAlone() {
        #expect(theme.styled(.normal) == theme)
    }

    @Test func cleanNeutralizesAccentChromeAndShadows() {
        let clean = theme.styled(.clean)
        #expect(clean.colors[.accentSoft] == theme.colors[.panelHover])
        #expect(clean.colors[.accentFaint] == theme.colors[.panelHover])
        #expect(clean.colors[.accentBorder] == theme.colors[.borderStrong])
        #expect(clean.colors[.borderAccent] == theme.colors[.border])
        #expect(clean.colors[.accent] == theme.colors[.accent], "the accent itself stays")
        #expect(clean.colors[.statusWorking] == theme.colors[.statusWorking], "status colors stay")
        #expect(ShadowLevel.allCases.allSatisfy { clean.shadow($0).blur == 0 })
        #expect(clean.validationErrors.isEmpty)
    }

    @Test func cleanRadiiAreTighterAndStillScale() {
        let normal = Metrics(scale: 1), clean = Metrics(scale: 1, style: .clean)
        #expect(clean.radius(.sm) == 3 && clean.radius(.md) == 4 && clean.radius(.lg) == 6)
        #expect(normal.radius(.lg) == 14)
        #expect(Metrics(scale: 1.5, style: .clean).radius(.md) == 6)
    }

    @Test func metricsCarryReducedMotion() {
        #expect(!Metrics().reducesMotion)
        #expect(Metrics(reducesMotion: true).reducesMotion)
    }
}
