const std = @import("std");
const c = @import("c.zig");
const freetype = @import("main.zig");
const errors = @import("errors.zig");
const Error = errors.Error;
const intToError = errors.intToError;

/// Convert a bitmap object with depth 1bpp, 2bpp, 4bpp, 8bpp or 32bpp to a
/// bitmap object with depth 8bpp, making the number of used bytes per line
/// (a.k.a. the ‘pitch’) a multiple of alignment.
pub fn bitmapConvert(
    lib: freetype.Library,
    source: *const c.FT_Bitmap,
    target: *c.FT_Bitmap,
    alignment: u32,
) Error!void {
    try intToError(c.FT_Bitmap_Convert(
        lib.handle,
        source,
        target,
        alignment,
    ));
}
