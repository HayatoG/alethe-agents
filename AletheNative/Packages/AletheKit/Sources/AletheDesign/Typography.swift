import AppKit
import CoreText
import SwiftUI

/// Text styles. UI text uses the system font (SF Pro), which applies size-specific tracking and
/// optical sizing itself; sizes follow macOS conventions and scale with `Metrics.scale`.
public enum TextStyle: CaseIterable, Sendable {
    case caption, footnote, body, headline, title3, title2, title1, largeTitle

    var size: CGFloat {
        switch self {
        case .caption: 10
        case .footnote: 11
        case .body: 13
        case .headline: 13
        case .title3: 15
        case .title2: 17
        case .title1: 22
        case .largeTitle: 26
        }
    }

    var weight: Font.Weight {
        switch self {
        case .headline: .semibold
        case .title1, .title2, .title3, .largeTitle: .bold
        default: .regular
        }
    }

    /// Extra line spacing as a fraction of the size: looser for small text, tight for large titles.
    var leading: CGFloat {
        switch self {
        case .caption, .footnote, .body: 0.25
        case .headline, .title3: 0.2
        case .title2, .title1: 0.12
        case .largeTitle: 0.06
        }
    }
}

extension Metrics {
    public func font(_ style: TextStyle) -> Font {
        .system(size: style.size * scale, weight: style.weight)
    }

    /// A text style on a zoomable surface (the orchestrator board): the UI scale times the surface's
    /// own zoom, which may go below the UI scale's minimum.
    public func font(_ style: TextStyle, zoom: CGFloat) -> Font {
        .system(size: style.size * scale * zoom, weight: style.weight)
    }

    public func lineSpacing(_ style: TextStyle) -> CGFloat {
        style.size * scale * style.leading
    }

    public func monoFont(size: CGFloat = 13) -> Font {
        .custom(AletheFonts.terminalFamily, size: size * scale)
    }
}

extension View {
    /// Applies a text style with its font and leading.
    public func textStyle(_ style: TextStyle, metrics: Metrics) -> some View {
        font(metrics.font(style)).lineSpacing(metrics.lineSpacing(style))
    }
}

/// Fonts bundled with the app.
public enum AletheFonts {
    /// Nerd Font variant of Cascadia Code (SIL OFL 1.1): full glyph coverage for TUIs.
    public static let terminalFamily = "CaskaydiaCove Nerd Font Mono"

    private static let registration: Bool = {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else {
            return false
        }
        var ok = true
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered in this process is fine; anything else is a real failure.
                let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
            }
        }
        return ok
    }()

    /// Registers the bundled fonts for this process. Idempotent.
    @discardableResult
    public static func registerBundledFonts() -> Bool { registration }
}
