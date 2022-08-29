//! Family represents a multiple styles of a single font: regular, bold,
//! italic, etc. It is able to cache the glyphs into a single atlas.
const Family = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atlas = @import("../Atlas.zig");
const Face = @import("main.zig").Face;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;
const testFont = @import("test.zig").fontRegular;
const codepoint = @import("main.zig").codepoint;
const Library = @import("main.zig").Library;

const log = std.log.scoped(.font_family);

/// The texture atlas where all the font glyphs are rendered.
/// This is NOT owned by the Family, deinitialization must
/// be manually done.
atlas: Atlas,

/// The library shared state.
lib: Library,

/// The glyphs that are loaded into the atlas, keyed by codepoint.
glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .{},

/// The font faces representing all the styles in this family.
/// These should be set directly or via various loader functions.
regular: ?Face = null,
bold: ?Face = null,

/// This struct is used for the hash key for glyphs.
const GlyphKey = struct {
    style: Style,
    codepoint: u32,
};

pub fn init(lib: Library, atlas: Atlas) Family {
    return .{
        .lib = lib,
        .atlas = atlas,
    };
}

pub fn deinit(self: *Family, alloc: Allocator) void {
    self.glyphs.deinit(alloc);

    if (self.regular) |*face| face.deinit();
    if (self.bold) |*face| face.deinit();

    self.* = undefined;
}

/// Loads a font to use from memory.
///
/// This can only be called if a font is not already loaded for the given style.
pub fn loadFaceFromMemory(
    self: *Family,
    comptime style: Style,
    source: [:0]const u8,
    size: Face.DesiredSize,
) !void {
    var face = try Face.init(self.lib);
    errdefer face.deinit();
    try face.loadFaceFromMemory(source, size);

    @field(self, switch (style) {
        .regular => "regular",
        .bold => "bold",
        .italic => unreachable,
        .bold_italic => unreachable,
    }) = face;
}

/// Get the glyph for the given codepoint and style. If the glyph hasn't
/// been loaded yet this will return null.
pub fn getGlyph(self: Family, cp: anytype, style: Style) ?*Glyph {
    const utf32 = codepoint(cp);
    const entry = self.glyphs.getEntry(.{
        .style = style,
        .codepoint = utf32,
    }) orelse return null;
    return entry.value_ptr;
}

/// Add a glyph. If the glyph has already been loaded this will return
/// the existing loaded glyph. If a glyph style can't be found, this will
/// fall back to the "regular" style. If a glyph can't be found in the
/// "regular" style, this will fall back to the unknown glyph character.
///
/// The codepoint can be either a u8 or  []const u8 depending on if you know
/// it is ASCII or must be UTF-8 decoded.
pub fn addGlyph(self: *Family, alloc: Allocator, v: anytype, style: Style) !*Glyph {
    const face = face: {
        // Real is the face we SHOULD use for this style.
        var real = switch (style) {
            .regular => self.regular,
            .bold => self.bold,
            .italic => unreachable,
            .bold_italic => unreachable,
        };

        // Fall back to regular if it is null
        if (real == null) real = self.regular;

        // Return our face if we have it.
        if (real) |ptr| break :face ptr;

        // If we reached this point, we have no font in the style we
        // want OR the fallback.
        return error.NoFontFallback;
    };

    // We need a UTF32 codepoint
    const utf32 = codepoint(v);

    // If we have this glyph loaded already then we're done.
    const glyphKey = .{
        .style = style,
        .codepoint = utf32,
    };
    const gop = try self.glyphs.getOrPut(alloc, glyphKey);
    if (gop.found_existing) return gop.value_ptr;
    errdefer _ = self.glyphs.remove(glyphKey);

    // Get the glyph and add it to the atlas.
    gop.value_ptr.* = try face.loadGlyph(alloc, &self.atlas, utf32);
    return gop.value_ptr;
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init();
    defer lib.deinit();

    var fam = init(lib, try Atlas.init(alloc, 512, .greyscale));
    defer fam.deinit(alloc);
    defer fam.atlas.deinit(alloc);
    try fam.loadFaceFromMemory(.regular, testFont, .{ .points = 12 });

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try fam.addGlyph(alloc, i, .regular);
    }

    i = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(fam.getGlyph(i, .regular) != null);
    }
}
