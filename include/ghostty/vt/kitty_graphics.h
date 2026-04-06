/**
 * @file kitty_graphics.h
 *
 * Kitty graphics protocol image storage.
 */

#ifndef GHOSTTY_VT_KITTY_GRAPHICS_H
#define GHOSTTY_VT_KITTY_GRAPHICS_H

#include <stdbool.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup kitty_graphics Kitty Graphics
 *
 * Opaque handle to the Kitty graphics image storage associated with a
 * terminal screen, and an iterator for inspecting placements.
 *
 * @{
 */

/**
 * Queryable data kinds for ghostty_kitty_graphics_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_GRAPHICS_DATA_INVALID = 0,

  /**
   * Populate a pre-allocated placement iterator with placement data from
   * the storage. Iterator data is only valid as long as the underlying
   * terminal is not mutated.
   *
   * Output type: GhosttyKittyGraphicsPlacementIterator *
   */
  GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR = 1,
} GhosttyKittyGraphicsData;

/**
 * Queryable data kinds for ghostty_kitty_graphics_placement_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_INVALID = 0,

  /**
   * The image ID this placement belongs to.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID = 1,

  /**
   * The placement ID.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID = 2,

  /**
   * Whether this is a virtual placement (unicode placeholder).
   *
   * Output type: bool *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL = 3,

  /**
   * Pixel offset from the left edge of the cell.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET = 4,

  /**
   * Pixel offset from the top edge of the cell.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET = 5,

  /**
   * Source rectangle x origin in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_X = 6,

  /**
   * Source rectangle y origin in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_Y = 7,

  /**
   * Source rectangle width in pixels (0 = full image width).
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_WIDTH = 8,

  /**
   * Source rectangle height in pixels (0 = full image height).
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_HEIGHT = 9,

  /**
   * Number of columns this placement occupies.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS = 10,

  /**
   * Number of rows this placement occupies.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS = 11,

  /**
   * Z-index for this placement.
   *
   * Output type: int32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z = 12,
} GhosttyKittyGraphicsPlacementData;

/**
 * Pixel format of a Kitty graphics image.
 *
 * @ingroup kitty_graphics
 */
typedef enum {
  GHOSTTY_KITTY_IMAGE_FORMAT_RGB = 0,
  GHOSTTY_KITTY_IMAGE_FORMAT_RGBA = 1,
  GHOSTTY_KITTY_IMAGE_FORMAT_PNG = 2,
  GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA = 3,
  GHOSTTY_KITTY_IMAGE_FORMAT_GRAY = 4,
} GhosttyKittyImageFormat;

/**
 * Compression of a Kitty graphics image.
 *
 * @ingroup kitty_graphics
 */
typedef enum {
  GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE = 0,
  GHOSTTY_KITTY_IMAGE_COMPRESSION_ZLIB_DEFLATE = 1,
} GhosttyKittyImageCompression;

/**
 * Queryable data kinds for ghostty_kitty_graphics_image_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_IMAGE_DATA_INVALID = 0,

  /**
   * The image ID.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_ID = 1,

  /**
   * The image number.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_NUMBER = 2,

  /**
   * Image width in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_WIDTH = 3,

  /**
   * Image height in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_HEIGHT = 4,

  /**
   * Pixel format of the image.
   *
   * Output type: GhosttyKittyImageFormat *
   */
  GHOSTTY_KITTY_IMAGE_DATA_FORMAT = 5,

  /**
   * Compression of the image.
   *
   * Output type: GhosttyKittyImageCompression *
   */
  GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION = 6,

  /**
   * Borrowed pointer to the raw pixel data. Valid as long as the
   * underlying terminal is not mutated.
   *
   * Output type: const uint8_t **
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR = 7,

  /**
   * Length of the raw pixel data in bytes.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN = 8,
} GhosttyKittyGraphicsImageData;

/**
 * Get data from a kitty graphics storage instance.
 *
 * The output pointer must be of the appropriate type for the requested
 * data kind.
 *
 * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
 *
 * @param graphics The kitty graphics handle
 * @param data The type of data to extract
 * @param[out] out Pointer to store the extracted data
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_get(
    GhosttyKittyGraphics graphics,
    GhosttyKittyGraphicsData data,
    void* out);

/**
 * Look up a Kitty graphics image by its image ID.
 *
 * Returns NULL if no image with the given ID exists or if Kitty graphics
 * are disabled at build time.
 *
 * @param graphics The kitty graphics handle
 * @param image_id The image ID to look up
 * @return An opaque image handle, or NULL if not found
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyKittyGraphicsImage ghostty_kitty_graphics_image(
    GhosttyKittyGraphics graphics,
    uint32_t image_id);

/**
 * Get data from a Kitty graphics image.
 *
 * The output pointer must be of the appropriate type for the requested
 * data kind.
 *
 * @param image The image handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get(
    GhosttyKittyGraphicsImage image,
    GhosttyKittyGraphicsImageData data,
    void* out);

/**
 * Create a new placement iterator instance.
 *
 * All fields except the allocator are left undefined until populated
 * via ghostty_kitty_graphics_get() with
 * GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyKittyGraphicsPlacementIterator* out_iterator);

/**
 * Free a placement iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API void ghostty_kitty_graphics_placement_iterator_free(
    GhosttyKittyGraphicsPlacementIterator iterator);

/**
 * Advance the placement iterator to the next placement.
 *
 * @param iterator The iterator handle (may be NULL)
 * @return true if advanced to the next placement, false if at the end
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API bool ghostty_kitty_graphics_placement_next(
    GhosttyKittyGraphicsPlacementIterator iterator);

/**
 * Get data from the current placement in a placement iterator.
 *
 * Call ghostty_kitty_graphics_placement_next() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the
 *         iterator is NULL or not positioned on a placement
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsPlacementData data,
    void* out);

/**
 * Compute the grid rectangle occupied by the current placement.
 *
 * Uses the placement's pin, the image dimensions, and the terminal's
 * cell/pixel geometry to calculate the bounding rectangle. Virtual
 * placements (unicode placeholders) return GHOSTTY_NO_VALUE.
 *
 * @param terminal The terminal handle
 * @param image The image handle for this placement's image
 * @param iterator The placement iterator positioned on a placement
 * @param[out] out_selection On success, receives the bounding rectangle
 *             as a selection with rectangle=true
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE for
 *         virtual placements or when Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_rect(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    GhosttySelection* out_selection);

/**
 * Compute the rendered pixel size of the current placement.
 *
 * Takes into account the placement's source rectangle, specified
 * columns/rows, and aspect ratio to calculate the final rendered
 * pixel dimensions.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_width On success, receives the width in pixels
 * @param[out] out_height On success, receives the height in pixels
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE when
 *         Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_pixel_size(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    uint32_t* out_width,
    uint32_t* out_height);

/**
 * Compute the grid cell size of the current placement.
 *
 * Returns the number of columns and rows that the placement occupies
 * in the terminal grid. If the placement specifies explicit columns
 * and rows, those are returned directly; otherwise they are calculated
 * from the pixel size and cell dimensions.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_cols On success, receives the number of columns
 * @param[out] out_rows On success, receives the number of rows
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE when
 *         Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_grid_size(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    uint32_t* out_cols,
    uint32_t* out_rows);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_KITTY_GRAPHICS_H */
