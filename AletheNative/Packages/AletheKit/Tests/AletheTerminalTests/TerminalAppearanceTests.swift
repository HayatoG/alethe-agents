import AletheDesign
import GhosttyTerminal
import Testing
@testable import AletheTerminal

@Suite struct TerminalAppearanceTests {
    @Test func blendsTranslucentColorsOverTheBackground() throws {
        let background = try #require(ThemeColor(hex: "#000000"))
        let halfWhite = try #require(ThemeColor(hex: "#ffffff80"))
        #expect(TerminalAppearance.opaqueHex(halfWhite, over: background) == "#808080")
        let opaque = try #require(ThemeColor(hex: "#12abef"))
        #expect(TerminalAppearance.opaqueHex(opaque, over: background) == "#12abef")
    }

    @Test func configurationCarriesFontAndFullPalette() {
        let rendered = TerminalAppearance.configuration(for: ThemeCatalog.builtin.defaultTheme).rendered
        #expect(rendered.contains("font-family = \(AletheFonts.terminalFamily)"))
        #expect(rendered.contains("palette = 15="))
        #expect(rendered.contains("background = #0c0c0c"))
    }

    /// Regression (ADR-10): Ghostty's default keybinds claimed ⌘W and other app shortcuts.
    @Test func clearsGhosttyKeybinds() {
        let rendered = TerminalAppearance.configuration(for: ThemeCatalog.builtin.defaultTheme).rendered
        #expect(rendered.contains("keybind = clear"))
    }

    /// Regression: the wrapper's default theme is rendered last and used to override our colors.
    @MainActor @Test func controllerRendersTheAletheThemeLast() throws {
        let controller = TerminalController(theme: TerminalAppearance.terminalTheme(for: ThemeCatalog.builtin.defaultTheme))
        let lastBackground = controller.renderedConfig
            .split(separator: "\n").last { $0.hasPrefix("background = ") }
        #expect(lastBackground == "background = #0c0c0c")
    }
}
