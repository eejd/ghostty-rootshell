//! Various conversions from Freetype formats to Atlas formats. These are
//! currently implemented naively. There are definitely MUCH faster ways
//! to do this (likely using SIMD), but I started simple.
const std = @import("std");
const freetype = @import("freetype");
const Atlas = @import("../Atlas.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The mapping from freetype format to atlas format.
pub const map = genMap();

/// The map type.
pub const Map = [freetype.c.FT_PIXEL_MODE_MAX]AtlasArray;

/// Conversion function type. The returning bitmap buffer is guaranteed
/// to be exactly `width * rows * depth` long for freeing it. The caller must
/// free the bitmap buffer. The depth is the depth of the atlas format in the
/// map.
pub const Func = fn (Allocator, Bitmap) Allocator.Error!Bitmap;

/// Alias for the freetype FT_Bitmap type to make it easier to type.
pub const Bitmap = freetype.c.struct_FT_Bitmap_;

const AtlasArray = std.EnumArray(Atlas.Format, ?Func);

fn genMap() Map {
    var result: Map = undefined;

    // Initialize to no converter
    var i: usize = 0;
    while (i < freetype.c.FT_PIXEL_MODE_MAX) : (i += 1) {
        result[i] = AtlasArray.initFill(null);
    }

    // Map our converters
    result[freetype.c.FT_PIXEL_MODE_MONO].set(.rgba, monoToRGBA);

    return result;
}

pub fn monoToRGBA(alloc: Allocator, bm: Bitmap) Allocator.Error!Bitmap {
    // NOTE: This was never tested and may not work. I wrote it to
    // solve another issue where this ended up not being needed.
    // TODO: test this!

    const depth = Atlas.Format.rgba.depth();
    var buf = try alloc.alloc(u8, bm.width * bm.rows * depth);
    errdefer alloc.free(buf);

    var i: usize = 0;
    while (i < bm.width * bm.rows) : (i += 1) {
        var bit: u3 = 0;
        while (bit <= 7) : (bit += 1) {
            const mask = @as(u8, 1) << (7 - bit);
            const bitval: u8 = if (bm.buffer[i] & mask > 0) 0xFF else 0;
            const buf_i = (i * 8 * depth) + (bit * depth);
            buf[buf_i] = 0xFF - bitval;
            buf[buf_i + 1] = 0xFF - bitval;
            buf[buf_i + 2] = 0xFF - bitval;
            buf[buf_i + 3] = bitval;
        }
    }

    var copy = bm;
    copy.buffer = buf.ptr;
    copy.pixel_mode = freetype.c.FT_PIXEL_MODE_BGRA;
    return copy;
}

test {
    _ = map;
}
