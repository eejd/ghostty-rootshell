const std = @import("std");
const c = @import("c.zig");
const errors = @import("errors.zig");
const Library = @import("Library.zig");
const Error = errors.Error;
const intToError = errors.intToError;

pub const Face = struct {
    handle: c.FT_Face,

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    /// A macro that returns true whenever a face object contains some
    /// embedded bitmaps. See the available_sizes field of the FT_FaceRec structure.
    pub fn hasFixedSizes(self: Face) bool {
        return c.FT_HAS_FIXED_SIZES(self.handle);
    }

    /// Select a given charmap by its encoding tag (as listed in freetype.h).
    pub fn selectCharmap(self: Face, encoding: Encoding) Error!void {
        return intToError(c.FT_Select_Charmap(self.handle, @enumToInt(encoding)));
    }

    /// Call FT_Request_Size to request the nominal size (in points).
    pub fn setCharSize(
        self: Face,
        char_width: i32,
        char_height: i32,
        horz_resolution: u16,
        vert_resolution: u16,
    ) Error!void {
        return intToError(c.FT_Set_Char_Size(
            self.handle,
            char_width,
            char_height,
            horz_resolution,
            vert_resolution,
        ));
    }
};

/// An enumeration to specify character sets supported by charmaps. Used in the
/// FT_Select_Charmap API function.
pub const Encoding = enum(u31) {
    none = c.FT_ENCODING_NONE,
    ms_symbol = c.FT_ENCODING_MS_SYMBOL,
    unicode = c.FT_ENCODING_UNICODE,
    sjis = c.FT_ENCODING_SJIS,
    prc = c.FT_ENCODING_PRC,
    big5 = c.FT_ENCODING_BIG5,
    wansung = c.FT_ENCODING_WANSUNG,
    johab = c.FT_ENCODING_JOHAB,
    adobe_standard = c.FT_ENCODING_ADOBE_STANDARD,
    adobe_expert = c.FT_ENCODING_ADOBE_EXPERT,
    adobe_custom = c.FT_ENCODING_ADOBE_CUSTOM,
    adobe_latin_1 = c.FT_ENCODING_ADOBE_LATIN_1,
    old_latin_2 = c.FT_ENCODING_OLD_LATIN_2,
    apple_roman = c.FT_ENCODING_APPLE_ROMAN,
};

test "loading memory font" {
    const testing = std.testing;
    const font_data = @import("test.zig").font_regular;

    var lib = try Library.init();
    defer lib.deinit();
    var face = try lib.initMemoryFace(font_data, 0);
    defer face.deinit();

    // Try APIs
    try face.selectCharmap(.unicode);
    try testing.expect(!face.hasFixedSizes());
    try face.setCharSize(12, 0, 0, 0);
}
