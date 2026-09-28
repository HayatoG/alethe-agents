import CAletheGlyphGuard

/// Keeps a zero-size SF Symbol from crashing the app on macOS 27 (see `alethe_glyph_guard.m`).
public enum SymbolRenderingGuard {
    /// Call once at launch, before any window renders.
    public static func install() {
        alethe_install_vector_glyph_guard()
    }
}
