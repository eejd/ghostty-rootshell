const std = @import("std");
const c = @import("c.zig");
const Font = @import("font.zig").Font;
const Buffer = @import("buffer.zig").Buffer;
const Feature = @import("common.zig").Feature;

/// Shapes buffer using font turning its Unicode characters content to
/// positioned glyphs. If features is not NULL, it will be used to control
/// the features applied during shaping. If two features have the same tag
/// but overlapping ranges the value of the feature with the higher index
/// takes precedence.
pub fn shape(font: Font, buf: Buffer, features: ?[]const Feature) void {
    c.hb_shape(
        font.handle,
        buf.handle,
        if (features) |f| @ptrCast([*]const c.hb_feature_t, f.ptr) else null,
        if (features) |f| @intCast(c_uint, f.len) else 0,
    );
}
