/**
 * @file unicode.h
 *
 * Unicode utilities - codepoint properties matching the terminal's
 * text layout semantics.
 */

#ifndef GHOSTTY_VT_UNICODE_H
#define GHOSTTY_VT_UNICODE_H

/** @defgroup unicode Unicode Utilities
 *
 * Unicode codepoint properties matching the terminal's text layout
 * semantics.
 *
 * ## Basic Usage
 *
 * Use ghostty_unicode_codepoint_width() to determine how many terminal
 * grid cells a codepoint occupies, using the exact same width table the
 * terminal itself uses when laying out printed text. This is useful for
 * predicting column layout of text that has not yet been written to the
 * terminal, such as IME preedit (composition) overlays.
 *
 * @{
 */

#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Returns the terminal display width of a Unicode codepoint in
 * terminal grid cells: 0, 1, or 2.
 *
 * This is the same width table the terminal itself uses when laying
 * out printed text, so callers can predict column layout (e.g. IME
 * preedit overlays) that exactly matches what the terminal will do
 * when the text is actually written to it.
 *
 * Semantics:
 * - Returns 0 for zero-width codepoints: C0/C1 control characters,
 *   nonspacing and enclosing combining marks, default-ignorable
 *   codepoints (ZWJ, ZWNJ, variation selectors, etc.), and
 *   surrogate codepoints.
 * - Returns 2 for wide codepoints: East Asian Wide/Fullwidth
 *   (including emoji with default emoji presentation) and regional
 *   indicators. Width is clamped to 2 (e.g. the three-em dash).
 * - Returns 1 for everything else, including invalid codepoints
 *   beyond U+10FFFF (this function is total; it never fails).
 *
 * This operates on a single codepoint only and therefore cannot
 * account for grapheme-cluster-level width rules (VS16 emoji
 * presentation, combining sequences, etc.). Callers wanting
 * cluster-accurate widths must segment text into grapheme clusters
 * themselves and combine per-codepoint widths.
 *
 * This function is pure, allocates nothing, and is thread-safe.
 *
 * @param cp The Unicode codepoint to measure
 * @return Display width in cells: 0, 1, or 2
 */
GHOSTTY_API uint8_t ghostty_unicode_codepoint_width(uint32_t cp);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_UNICODE_H */
