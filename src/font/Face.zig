//! Face represents a single font face. A single font face has a single set
//! of properties associated with it such as style, weight, etc.
//!
//! A Face isn't typically meant to be used directly. It is usually used
//! via a Family in order to store it in an Atlas.
const Face = @This();

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ftc = @import("freetype").c;
const Atlas = @import("../Atlas.zig");
const Glyph = @import("main.zig").Glyph;

const ftok = ftc.FT_Err_Ok;
const log = std.log.scoped(.font_face);

/// The FreeType library
ft_library: ftc.FT_Library,

/// Our font face.
ft_face: ftc.FT_Face = null,

pub fn init(lib: ftc.FT_Library) !Face {
    return Face{
        .ft_library = lib,
    };
}

pub fn deinit(self: *Face) void {
    if (self.ft_face != null) {
        if (ftc.FT_Done_Face(self.ft_face) != ftok)
            log.err("failed to clean up font face", .{});
    }

    self.* = undefined;
}

/// Loads a font to use.
///
/// This can only be called if a font is not already loaded.
pub fn loadFaceFromMemory(self: *Face, source: [:0]const u8, size: u32) !void {
    assert(self.ft_face == null);

    if (ftc.FT_New_Memory_Face(
        self.ft_library,
        source.ptr,
        @intCast(c_long, source.len),
        0,
        &self.ft_face,
    ) != ftok) return error.FaceLoadFailed;
    errdefer {
        _ = ftc.FT_Done_Face(self.ft_face);
        self.ft_face = null;
    }

    if (ftc.FT_Select_Charmap(self.ft_face, ftc.FT_ENCODING_UNICODE) != ftok)
        return error.FaceLoadFailed;

    // If we have fixed sizes, we just have to try to pick the one closest
    // to what the user requested. Otherwise, we can choose an arbitrary
    // pixel size.
    if (!ftc.FT_HAS_FIXED_SIZES(self.ft_face)) {
        if (ftc.FT_Set_Pixel_Sizes(self.ft_face, size, size) != ftok)
            return error.FaceLoadFailed;
    } else try self.selectSizeNearest(size);
}

/// Selects the fixed size in the loaded face that is closest to the
/// requested pixel size.
fn selectSizeNearest(self: *Face, size: u32) !void {
    var i: usize = 0;
    var best_i: usize = 0;
    var best_diff: i32 = 0;
    while (i < self.ft_face.*.num_fixed_sizes) : (i += 1) {
        const diff = @intCast(i32, size) - @intCast(i32, self.ft_face.*.available_sizes[i].width);
        if (i == 0 or diff < best_diff) {
            best_diff = diff;
            best_i = i;
        }
    }

    if (ftc.FT_Select_Size(self.ft_face, @intCast(c_int, best_i)) != ftok)
        return error.FaceSelectSizeFailed;
}

/// Load a glyph for this face. The codepoint can be either a u8 or
/// []const u8 depending on if you know it is ASCII or must be UTF-8 decoded.
pub fn loadGlyph(self: Face, alloc: Allocator, atlas: *Atlas, cp: u32) !Glyph {
    assert(self.ft_face != null);

    // We need a UTF32 codepoint for freetype
    const glyph_index = glyph_index: {
        //log.warn("glyph load: {x}", .{cp});
        const idx = ftc.FT_Get_Char_Index(self.ft_face, cp);
        if (idx > 0) break :glyph_index idx;

        // Unknown glyph.
        //log.warn("glyph not found: {x}", .{cp});
        return error.GlyphNotFound;
    };
    //log.warn("glyph index: {}", .{glyph_index});

    // If our glyph has color, we want to render the color
    var load_flags: c_int = ftc.FT_LOAD_RENDER;
    if (ftc.FT_HAS_COLOR(self.ft_face)) load_flags |= @intCast(c_int, ftc.FT_LOAD_COLOR);

    if (ftc.FT_Load_Glyph(
        self.ft_face,
        glyph_index,
        load_flags,
    ) != ftok) return error.LoadGlyphFailed;

    const glyph = self.ft_face.*.glyph;
    const bitmap = glyph.*.bitmap;

    // Ensure we know how to work with the font format. And assure that
    // or color depth is as expected on the texture atlas.
    const format: Atlas.Format = switch (bitmap.pixel_mode) {
        ftc.FT_PIXEL_MODE_GRAY => .greyscale,
        ftc.FT_PIXEL_MODE_BGRA => .rgba,
        else => {
            log.warn("pixel mode={}", .{bitmap.pixel_mode});
            @panic("unsupported pixel mode");
        },
    };
    assert(atlas.format == format);

    const src_w = bitmap.width;
    const src_h = bitmap.rows;
    const tgt_w = src_w;
    const tgt_h = src_h;

    const region = try atlas.reserve(alloc, tgt_w, tgt_h);

    // If we have data, copy it into the atlas
    if (region.width > 0 and region.height > 0) {
        const depth = @enumToInt(format);

        // We can avoid a buffer copy if our atlas width and bitmap
        // width match and the bitmap pitch is just the width (meaning
        // the data is tightly packed).
        const needs_copy = !(tgt_w == bitmap.width and (bitmap.width * depth) == bitmap.pitch);

        // If we need to copy the data, we copy it into a temporary buffer.
        const buffer = if (needs_copy) buffer: {
            var temp = try alloc.alloc(u8, tgt_w * tgt_h * depth);
            var dst_ptr = temp;
            var src_ptr = bitmap.buffer;
            var i: usize = 0;
            while (i < src_h) : (i += 1) {
                std.mem.copy(u8, dst_ptr, src_ptr[0 .. bitmap.width * depth]);
                dst_ptr = dst_ptr[tgt_w * depth ..];
                src_ptr += @intCast(usize, bitmap.pitch);
            }
            break :buffer temp;
        } else bitmap.buffer[0..(tgt_w * tgt_h * depth)];
        defer if (buffer.ptr != bitmap.buffer) alloc.free(buffer);

        // Write the glyph information into the atlas
        assert(region.width == tgt_w);
        assert(region.height == tgt_h);
        atlas.set(region, buffer);
    }

    // Store glyph metadata
    return Glyph{
        .width = tgt_w,
        .height = tgt_h,
        .offset_x = glyph.*.bitmap_left,
        .offset_y = glyph.*.bitmap_top,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = f26dot6ToFloat(glyph.*.advance.x),
    };
}

/// Convert 16.6 pixel format to pixels based on the scale factor of the
/// current font size.
pub fn unitsToPxY(self: Face, units: i32) i32 {
    return @intCast(i32, ftc.FT_MulFix(units, self.ft_face.*.size.*.metrics.y_scale) >> 6);
}

/// Convert 26.6 pixel format to f32
fn f26dot6ToFloat(v: ftc.FT_F26Dot6) f32 {
    return @intToFloat(f32, v >> 6);
}

test {
    const testFont = @import("test.zig").fontRegular;

    var ft_lib: ftc.FT_Library = undefined;
    if (ftc.FT_Init_FreeType(&ft_lib) != ftok)
        return error.FreeTypeInitFailed;
    defer _ = ftc.FT_Done_FreeType(ft_lib);

    const alloc = testing.allocator;
    var atlas = try Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var font = try init(ft_lib);
    defer font.deinit();

    try font.loadFaceFromMemory(testFont, 48);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try font.loadGlyph(alloc, &atlas, i);
    }
}

test "color emoji" {
    const testFont = @import("test.zig").fontEmoji;

    var ft_lib: ftc.FT_Library = undefined;
    if (ftc.FT_Init_FreeType(&ft_lib) != ftok)
        return error.FreeTypeInitFailed;
    defer _ = ftc.FT_Done_FreeType(ft_lib);

    const alloc = testing.allocator;
    var atlas = try Atlas.init(alloc, 512, .rgba);
    defer atlas.deinit(alloc);

    var font = try init(ft_lib);
    defer font.deinit();

    try font.loadFaceFromMemory(testFont, 48);
    _ = try font.loadGlyph(alloc, &atlas, '🥸');
}
