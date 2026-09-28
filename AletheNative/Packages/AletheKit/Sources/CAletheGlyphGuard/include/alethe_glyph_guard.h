#ifndef ALETHE_GLYPH_GUARD_H
#define ALETHE_GLYPH_GUARD_H

/// Makes SF Symbol rasterization at a zero size draw nothing instead of crashing the app.
/// Idempotent; call once at launch. See alethe_glyph_guard.m.
void alethe_install_vector_glyph_guard(void);

#endif
