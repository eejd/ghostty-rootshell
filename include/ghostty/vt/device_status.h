/**
 * @file device_status.h
 *
 * Device status types used by the terminal.
 */

#ifndef GHOSTTY_VT_DEVICE_STATUS_H
#define GHOSTTY_VT_DEVICE_STATUS_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Color scheme reported in response to a CSI ? 996 n query.
 *
 * @ingroup terminal
 */
typedef enum {
    GHOSTTY_COLOR_SCHEME_LIGHT = 0,
    GHOSTTY_COLOR_SCHEME_DARK = 1,
} GhosttyColorScheme;

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_DEVICE_STATUS_H */
