/**
 * @file kitty_graphics.h
 *
 * Kitty graphics protocol image storage.
 */

#ifndef GHOSTTY_VT_KITTY_GRAPHICS_H
#define GHOSTTY_VT_KITTY_GRAPHICS_H

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup kitty_graphics Kitty Graphics
 *
 * Opaque handle to the Kitty graphics image storage associated with a
 * terminal screen.
 *
 * @{
 */

/**
 * Opaque handle to a Kitty graphics image storage.
 *
 * Obtained via ghostty_terminal_get() with
 * GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS. The pointer is borrowed from
 * the terminal and remains valid until the next mutating terminal call
 * (e.g. ghostty_terminal_vt_write() or ghostty_terminal_reset()).
 *
 * @ingroup kitty_graphics
 */
typedef struct GhosttyKittyGraphicsImpl* GhosttyKittyGraphics;

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_KITTY_GRAPHICS_H */
