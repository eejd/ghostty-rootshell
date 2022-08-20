//! FallbackSet represents a set of families in priority order to load a glyph.
//! This can be used to merge multiple font families together to find a glyph
//! for a codepoint.
const FallbackSet = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ftc = @import("freetype").c;
const Atlas = @import("../Atlas.zig");
const Family = @import("main.zig").Family;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;

const ftok = ftc.FT_Err_Ok;
const log = std.log.scoped(.font_fallback);

/// The families to look for in order. This should be managed directly
/// by the caller of the set. Deinit will deallocate this.
families: std.ArrayListUnmanaged(Family) = .{},

/// A quick lookup that points directly to the family that loaded a glyph.
glyphs: std.AutoHashMapUnmanaged(GlyphKey, usize) = .{},

const GlyphKey = struct {
    style: Style,
    codepoint: u32,
};

pub fn deinit(self: *FallbackSet, alloc: Allocator) void {
    self.families.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.* = undefined;
}

pub const GetOrAdd = struct {
    /// Index of the family where the glyph was loaded from
    family: usize,

    /// True if the glyph was found or whether it was newly loaded
    found_existing: bool,

    /// The glyph
    glyph: *Glyph,
};

pub fn getOrAddGlyph(
    self: *FallbackSet,
    alloc: Allocator,
    v: anytype,
    style: Style,
) !GetOrAdd {
    assert(self.families.items.len > 0);

    // We need a UTF32 codepoint
    const utf32 = Family.codepoint(v);

    // If we have this already, load it directly
    const glyphKey: GlyphKey = .{ .style = style, .codepoint = utf32 };
    const gop = try self.glyphs.getOrPut(alloc, glyphKey);
    if (gop.found_existing) {
        const i = gop.value_ptr.*;
        assert(i < self.families.items.len);
        return GetOrAdd{
            .family = i,
            .found_existing = true,
            .glyph = self.families.items[i].getGlyph(v, style) orelse unreachable,
        };
    }
    errdefer _ = self.glyphs.remove(glyphKey);

    // Go through each familiy and look for a matching glyph
    var fam_i: usize = 0;
    const glyph = glyph: {
        var style_current = style;
        while (true) {
            for (self.families.items) |*family, i| {
                fam_i = i;

                // If this family already has it loaded, return it.
                if (family.getGlyph(v, style_current)) |glyph| break :glyph glyph;

                // Try to load it.
                if (family.addGlyph(alloc, v, style_current)) |glyph|
                    break :glyph glyph
                else |err| switch (err) {
                    error.GlyphNotFound => {},
                    else => return err,
                }
            }

            // We never found any glyph! For our first fallback, we'll simply
            // try to the non-styled variant.
            if (style_current == .regular) break;
            style_current = .regular;
        }

        // If we are regular, we use a fallback character
        log.warn("glyph not found, using fallback. codepoint={x}", .{utf32});
        break :glyph try self.families.items[0].addGlyph(alloc, ' ', style);
    };

    gop.value_ptr.* = fam_i;
    return GetOrAdd{
        .family = fam_i,
        .glyph = glyph,

        // Technically possible that we found this in a cache...
        .found_existing = false,
    };
}

test {
    const fontRegular = @import("test.zig").fontRegular;
    const fontEmoji = @import("test.zig").fontEmoji;

    const testing = std.testing;
    const alloc = testing.allocator;

    var set: FallbackSet = .{};
    try set.families.append(alloc, fam: {
        var fam = try Family.init(try Atlas.init(alloc, 512, .greyscale));
        try fam.loadFaceFromMemory(.regular, fontRegular, 48);
        break :fam fam;
    });
    try set.families.append(alloc, fam: {
        var fam = try Family.init(try Atlas.init(alloc, 512, .rgba));
        try fam.loadFaceFromMemory(.regular, fontEmoji, 48);
        break :fam fam;
    });

    defer {
        for (set.families.items) |*family| {
            family.atlas.deinit(alloc);
            family.deinit(alloc);
        }
        set.deinit(alloc);
    }

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try set.getOrAddGlyph(alloc, i, .regular);
    }

    // Emoji should work
    _ = try set.getOrAddGlyph(alloc, '🥸', .regular);
    _ = try set.getOrAddGlyph(alloc, '🥸', .bold);
}
