/**
 * @file render.h
 *
 * Render state for creating high performance renderers.
 */

#ifndef GHOSTTY_VT_RENDER_H
#define GHOSTTY_VT_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup render Render State
 *
 * Represents the state required to render a visible screen (a viewport)
 * of a terminal instance. This is stateful and optimized for repeated
 * updates from a single terminal instance and only updating dirty regions
 * of the screen.
 *
 * The key design principle of this API is that it only needs read/write
 * access to the terminal instance during the update call. This allows
 * the render state to minimally impact terminal IO performance and also
 * allows the renderer to be safely multi-threaded (as long as a lock is 
 * held during the update call to ensure exclusive access to the terminal 
 * instance).
 *
 * The basic usage of this API is:
 *
 *   1. Create an empty render state
 *   2. Update it from a terminal instance whenever you need.
 *   3. Read from the render state to get the data needed to draw your frame.
 *
 * ## Dirty Tracking
 *
 * Dirty tracking is a key feature of the render state that allows renderers
 * to efficiently determine what parts of the screen have changed and only 
 * redraw changed regions.
 *
 * The render state API keeps track of dirty state at two independent layers:
 * a global dirty state that indicates whether the entire frame is clean, 
 * partially dirty, or fully dirty, and a per-row dirty state that allows 
 * tracking which rows in a partially dirty frame have changed. 
 *
 * The user of the render state API is expected to unset both of these.
 * The `update` call does not unset dirty state, it only updates it.
 *
 * An extremely important detail: setting one dirty state doesn't unset
 * the other. For example, setting the global dirty state to false does not
 * reset the row-level dirty flags. So, the caller of the render state API must
 * be careful to manage both layers of dirty state correctly. 
 *
 * ## Example
 *
 * @snippet c-vt-render/src/main.c render-state-update
 *
 * @{
 */

/**
 * Opaque handle to a render state instance.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderState* GhosttyRenderState;

/**
 * Opaque handle to a render-state row iterator.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateRowIterator* GhosttyRenderStateRowIterator;

/**
 * Dirty state of a render state after update.
 *
 * @ingroup render
 */
typedef enum {
  /** Not dirty at all; rendering can be skipped. */
  GHOSTTY_RENDER_STATE_DIRTY_FALSE = 0,

  /** Some rows changed; renderer can redraw incrementally. */
  GHOSTTY_RENDER_STATE_DIRTY_PARTIAL = 1,

  /** Global state changed; renderer should redraw everything. */
  GHOSTTY_RENDER_STATE_DIRTY_FULL = 2,
} GhosttyRenderStateDirty;

/**
 * Queryable data kinds for ghostty_render_state_get().
 *
 * @ingroup render
 */
typedef enum {
  /** Invalid / sentinel value. */
  GHOSTTY_RENDER_STATE_DATA_INVALID = 0,

  /** Viewport width in cells (uint16_t). */
  GHOSTTY_RENDER_STATE_DATA_COLS = 1,

  /** Viewport height in cells (uint16_t). */
  GHOSTTY_RENDER_STATE_DATA_ROWS = 2,

  /** Current dirty state (GhosttyRenderStateDirty). */
  GHOSTTY_RENDER_STATE_DATA_DIRTY = 3,
} GhosttyRenderStateData;

/**
 * Settable options for ghostty_render_state_set().
 *
 * @ingroup render
 */
typedef enum {
  /** Set dirty state (GhosttyRenderStateDirty). */
  GHOSTTY_RENDER_STATE_OPTION_DIRTY = 0,
} GhosttyRenderStateOption;

/**
 * Render-state color information.
 *
 * This struct uses the sized-struct ABI pattern. Initialize with
 * GHOSTTY_INIT_SIZED(GhosttyRenderStateColors) before calling
 * ghostty_render_state_colors_get().
 *
 * Example:
 * @code
 * GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
 * GhosttyResult result = ghostty_render_state_colors_get(state, &colors);
 * @endcode
 *
 * @ingroup render
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyRenderStateColors). */
  size_t size;

  /** The default/current background color for the render state. */
  GhosttyColorRgb background;

  /** The default/current foreground color for the render state. */
  GhosttyColorRgb foreground;

  /** The cursor color when explicitly set by terminal state. */
  GhosttyColorRgb cursor;

  /** 
   * True when cursor contains a valid explicit cursor color value. 
   * If this is false, the cursor color should be ignored; it will 
   * contain undefined data.
   * */
  bool cursor_has_value;

  /** The active 256-color palette for this render state. */
  GhosttyColorRgb palette[256];
} GhosttyRenderStateColors;

/**
 * Create a new render state instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state Pointer to store the created render state handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 * failure
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_new(const GhosttyAllocator* allocator,
                                       GhosttyRenderState* state);

/**
 * Free a render state instance.
 *
 * Releases all resources associated with the render state. After this call,
 * the render state handle becomes invalid.
 *
 * @param state The render state handle to free (may be NULL)
 *
 * @ingroup render
 */
void ghostty_render_state_free(GhosttyRenderState state);

/**
 * Update a render state instance from a terminal.
 *
 * This consumes terminal/screen dirty state in the same way as the internal
 * render state update path.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal The terminal handle to read from (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 * `terminal` is NULL, GHOSTTY_OUT_OF_MEMORY if updating the state requires
 * allocation and that allocation fails
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_update(GhosttyRenderState state,
                                          GhosttyTerminal terminal);

/**
 * Get a value from a render state.
 *
 * The `out` pointer must point to a value of the type corresponding to the
 * requested data kind (see GhosttyRenderStateData).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL or `data` is not a recognized enum value
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_get(GhosttyRenderState state,
                                       GhosttyRenderStateData data,
                                       void* out);

/**
 * Set an option on a render state.
 *
 * The `value` pointer must point to a value of the type corresponding to the
 * requested option kind (see GhosttyRenderStateOption).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param[in] value Pointer to the value to set (NULL returns
 *            GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 *         `value` is NULL
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_set(GhosttyRenderState state,
                                       GhosttyRenderStateOption option,
                                       const void* value);

/**
 * Get the current color information from a render state.
 *
 * This writes as many fields as fit in the caller-provided sized struct.
 * `out_colors->size` must be set by the caller (typically via
 * GHOSTTY_INIT_SIZED(GhosttyRenderStateColors)).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_colors Sized output struct to receive render-state colors
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 *         `out_colors` is NULL, or if `out_colors->size` is smaller than
 *         `sizeof(size_t)`
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_colors_get(GhosttyRenderState state,
                                              GhosttyRenderStateColors* out_colors);

/**
 * Create a row iterator for a render state.
 *
 * The iterator borrows from `state`; `state` must outlive the iterator.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state The render state handle to iterate (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL, GHOSTTY_OUT_OF_MEMORY on allocation failure
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_row_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderState state,
    GhosttyRenderStateRowIterator* out_iterator);

/**
 * Free a render-state row iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup render
 */
void ghostty_render_state_row_iterator_free(GhosttyRenderStateRowIterator iterator);

/**
 * Move a render-state row iterator to the next row.
 *
 * Returns true if the iterator moved successfully and row data is
 * available to read at the new position.
 *
 * @param iterator The iterator handle to advance (may be NULL)
 * @return true if advanced to the next row, false if `iterator` is
 *         NULL or if the iterator has reached the end
 *
 * @ingroup render
 */
bool ghostty_render_state_row_iterator_next(GhosttyRenderStateRowIterator iterator);

/**
 * Get the dirty state of the current row in a render-state row iterator.
 *
 * This reads the dirty flag at the iterator's current row position.
 * Call ghostty_render_state_row_iterator_next() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle to query (may be NULL)
 * @return true if the current row is dirty, false if the row is clean,
 *         `iterator` is NULL, or the iterator is not positioned on a row
 *
 * @ingroup render
 */
bool ghostty_render_state_row_dirty_get(GhosttyRenderStateRowIterator iterator);

/**
 * Set the dirty state of the current row in a render-state row iterator.
 *
 * This writes the dirty flag at the iterator's current row position.
 * Call ghostty_render_state_row_iterator_next() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle to update (may be NULL)
 * @param dirty The dirty state to set for the current row
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if
 *         `iterator` is NULL or the iterator is not positioned on a row
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_row_dirty_set(
    GhosttyRenderStateRowIterator iterator,
    bool dirty);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_RENDER_H */
