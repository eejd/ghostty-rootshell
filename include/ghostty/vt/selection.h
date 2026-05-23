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

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SELECTION_H */
