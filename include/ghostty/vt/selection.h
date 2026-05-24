/**
 * @file selection.h
 *
 * Selection range type for specifying a region of terminal content.
 */

#ifndef GHOSTTY_VT_SELECTION_H
#define GHOSTTY_VT_SELECTION_H

#include <stdbool.h>
#include <stddef.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/point.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup selection Selection
 *
 * A snapshot selection range defined by two grid references that identifies
 * a contiguous or rectangular region of terminal content.
 *
 * The start and end values are GhosttyGridRef values. They are therefore
 * untracked grid references and inherit the same lifetime rules: they are
 * only safe to use until the next mutating operation on the terminal that
 * produced them, including freeing the terminal. To keep a selection valid
 * across terminal mutations, callers must maintain tracked grid references
 * for the endpoints and reconstruct a GhosttySelection from fresh snapshots
 * when needed.
 *
 * @{
 */

/**
 * A snapshot selection range defined by two grid references.
 *
 * Both endpoints are inclusive. The endpoints preserve selection direction
 * and may be reversed; callers must not assume that start is the top-left
 * endpoint or that end is the bottom-right endpoint.
 *
 * When rectangle is false, the endpoints describe a linear selection. When
 * rectangle is true, the same endpoints are interpreted as opposite corners
 * of a rectangular/block selection.
 *
 * The start and end values are untracked GhosttyGridRef snapshots and are
 * only valid until the next mutating operation on the terminal that produced
 * them unless the selection is reconstructed from tracked references.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttySelection). */
  size_t size;

  /**
   * Start of the selection range (inclusive).
   *
   * This may be after end in terminal order. It is an untracked
   * GhosttyGridRef snapshot and follows untracked grid-ref lifetime rules.
   */
  GhosttyGridRef start;

  /**
   * End of the selection range (inclusive).
   *
   * This may be before start in terminal order. It is an untracked
   * GhosttyGridRef snapshot and follows untracked grid-ref lifetime rules.
   */
  GhosttyGridRef end;

  /**
   * Whether the endpoints are interpreted as a rectangular/block selection
   * rather than a linear selection.
   */
  bool rectangle;
} GhosttySelection;

/**
 * Ordering of a selection's endpoints in terminal coordinates.
 *
 * Mirrored orders are only produced by rectangular selections whose start
 * and end endpoints are on opposite diagonal corners that are not simple
 * top-left-to-bottom-right or bottom-right-to-top-left orderings.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Start is before end in top-left to bottom-right order. */
  GHOSTTY_SELECTION_ORDER_FORWARD = 0,

  /** End is before start in top-left to bottom-right order. */
  GHOSTTY_SELECTION_ORDER_REVERSE = 1,

  /** Rectangular selection from top-right to bottom-left. */
  GHOSTTY_SELECTION_ORDER_MIRRORED_FORWARD = 2,

  /** Rectangular selection from bottom-left to top-right. */
  GHOSTTY_SELECTION_ORDER_MIRRORED_REVERSE = 3,

  GHOSTTY_SELECTION_ORDER_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionOrder;

/**
 * Operation used to adjust a selection endpoint.
 *
 * Adjustment mutates the selection's logical end endpoint, not whichever
 * endpoint is visually bottom/right. This preserves keyboard and drag
 * behavior for both forward and reversed selections.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Move left to the previous non-empty cell, wrapping upward. */
  GHOSTTY_SELECTION_ADJUST_LEFT = 0,

  /** Move right to the next non-empty cell, wrapping downward. */
  GHOSTTY_SELECTION_ADJUST_RIGHT = 1,

  /**
   * Move up one row at the current column, or to the beginning of the
   * line if already at the top.
   */
  GHOSTTY_SELECTION_ADJUST_UP = 2,

  /**
   * Move down to the next non-blank row at the current column, or to the
   * end of the line if none exists.
   */
  GHOSTTY_SELECTION_ADJUST_DOWN = 3,

  /** Move to the top-left cell of the screen. */
  GHOSTTY_SELECTION_ADJUST_HOME = 4,

  /** Move to the right edge of the last non-blank row on the screen. */
  GHOSTTY_SELECTION_ADJUST_END = 5,

  /**
   * Move up by one terminal page height, or to home if that would move
   * past the top.
   */
  GHOSTTY_SELECTION_ADJUST_PAGE_UP = 6,

  /**
   * Move down by one terminal page height, or to end if that would move
   * past the bottom.
   */
  GHOSTTY_SELECTION_ADJUST_PAGE_DOWN = 7,

  /** Move to the left edge of the current line. */
  GHOSTTY_SELECTION_ADJUST_BEGINNING_OF_LINE = 8,

  /** Move to the right edge of the current line. */
  GHOSTTY_SELECTION_ADJUST_END_OF_LINE = 9,

  GHOSTTY_SELECTION_ADJUST_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionAdjust;

/**
 * Adjust a selection snapshot using terminal selection semantics.
 *
 * This mutates the caller-provided GhosttySelection in place. The logical end
 * endpoint is always moved, regardless of whether the selection is forward or
 * reversed visually. The input selection remains a snapshot: after adjustment,
 * call ghostty_terminal_set() with GHOSTTY_TERMINAL_OPT_SELECTION to install it
 * as the terminal-owned selection if desired.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to adjust in place
 * @param adjustment The adjustment operation to apply
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, or adjustment are invalid. Selection reference validity
 *         is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_adjust(
                                    GhosttyTerminal terminal,
                                    GhosttySelection* selection,
                                    GhosttySelectionAdjust adjustment);

/**
 * Get the current endpoint ordering of a selection snapshot.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param[out] out_order On success, receives the selection order
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_order(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttySelectionOrder* out_order);

/**
 * Return a selection snapshot with endpoints ordered as requested.
 *
 * Use GHOSTTY_SELECTION_ORDER_FORWARD to get top-left to bottom-right bounds,
 * and GHOSTTY_SELECTION_ORDER_REVERSE to get bottom-right to top-left bounds.
 * Mirrored desired orders are accepted but normalized the same as forward.
 * The output selection is a fresh untracked snapshot and is not installed as
 * the terminal's current selection.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to order
 * @param desired Desired endpoint order
 * @param[out] out_selection On success, receives the ordered selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, desired order, or output pointer are invalid. Selection
 *         reference validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_ordered(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttySelectionOrder desired,
                                    GhosttySelection* out_selection);

/**
 * Test whether a terminal point is inside a selection snapshot.
 *
 * This uses the same selection semantics as the terminal, including
 * rectangular/block selections and linear selections spanning multiple rows.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param point Point to test for containment
 * @param[out] out_contains On success, receives whether point is inside selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, point, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_contains(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttyPoint point,
                                    bool* out_contains);

/**
 * Test whether two selection snapshots are equal.
 *
 * Equality uses the terminal's internal selection semantics: both endpoint
 * pins must match and both selections must have the same rectangular/block
 * state. This avoids requiring callers to compare raw GhosttyGridRef internals.
 *
 * Both selections' start and end grid refs must be valid untracked snapshots
 * for the given terminal's currently active screen. In practice, they must
 * come from that terminal and screen, and no mutating terminal call may have
 * occurred since the refs were produced or reconstructed from tracked refs.
 * Passing refs from another terminal, another screen, or stale refs violates
 * this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param a First selection snapshot to compare
 * @param b Second selection snapshot to compare
 * @param[out] out_equal On success, receives whether the selections are equal
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selections, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_equal(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* a,
                                    const GhosttySelection* b,
                                    bool* out_equal);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SELECTION_H */
