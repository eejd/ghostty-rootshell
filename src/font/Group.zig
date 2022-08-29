//! A font group is a a set of multiple font faces of potentially different
//! styles that are used together to find glyphs. They usually share sizing
//! properties so that they can be used interchangably with each other in cases
//! a codepoint doesn't map cleanly. For example, if a user requests a bold
//! char and it doesn't exist we can fallback to a regular non-bold char so
//! we show SOMETHING.
const Group = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Atlas = @import("../Atlas.zig");
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;

const log = std.log.scoped(.font_group);

/// Packed array to map our styles to a set of faces.
// Note: this is not the most efficient way to store these, but there is
// usually only one font group for the entire process so this isn't the
// most important memory efficiency we can look for. This is totally opaque
// to the user so we can change this later.
const StyleArray = std.EnumArray(Style, std.ArrayListUnmanaged(Face));

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Group.
faces: StyleArray,

pub fn init(alloc: Allocator) !Group {
    var result = Group{ .faces = undefined };

    // Initialize all our styles to initially sized lists.
    var i: usize = 0;
    while (i < StyleArray.len) : (i += 1) {
        result.faces.values[i] = .{};
        try result.faces.values[i].ensureTotalCapacityPrecise(alloc, 2);
    }

    return result;
}

pub fn deinit(self: *Group, alloc: Allocator) void {
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*item| item.deinit();
        entry.value.deinit(alloc);
    }
}

/// Add a face to the list for the given style. This face will be added as
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// The group takes ownership of the face. The face will be deallocated when
/// the group is deallocated.
pub fn addFace(self: *Group, alloc: Allocator, style: Style, face: Face) !void {
    try self.faces.getPtr(style).append(alloc, face);
}

/// This represents a specific font in the group.
pub const FontIndex = packed struct {
    /// The number of bits we use for the index.
    const idx_bits = 8 - @typeInfo(@typeInfo(Style).Enum.tag_type).Int.bits;
    pub const IndexInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = idx_bits } });

    style: Style = .regular,
    idx: IndexInt = 0,

    /// Convert to int
    pub fn int(self: FontIndex) u8 {
        return @bitCast(u8, self);
    }

    test {
        // We never want to take up more than a byte since font indexes are
        // everywhere so if we increase the size of this we'll dramatically
        // increase our memory usage.
        try std.testing.expectEqual(@sizeOf(u8), @sizeOf(FontIndex));
    }
};

/// Looks up the font that should be used for a specific codepoint.
/// The font index is valid as long as font faces aren't removed. This
/// isn't cached; it is expected that downstream users handle caching if
/// that is important.
pub fn indexForCodepoint(self: Group, style: Style, cp: u32) ?FontIndex {
    // If we can find the exact value, then return that.
    if (self.indexForCodepointExact(style, cp)) |value| return value;

    // If this is already regular, we're done falling back.
    if (style == .regular) return null;

    // For non-regular fonts, we fall back to regular.
    return self.indexForCodepointExact(.regular, cp);
}

fn indexForCodepointExact(self: Group, style: Style, cp: u32) ?FontIndex {
    for (self.faces.get(style).items) |face, i| {
        if (face.glyphIndex(cp) != null) {
            return FontIndex{
                .style = style,
                .idx = @intCast(FontIndex.IndexInt, i),
            };
        }
    }

    // Not found
    return null;
}

/// Return the Face represented by a given FontIndex.
pub fn faceFromIndex(self: Group, index: FontIndex) Face {
    return self.faces.get(index.style).items[@intCast(usize, index.idx)];
}

/// Render a glyph by glyph index into the given font atlas and return
/// metadata about it.
///
/// This performs no caching, it is up to the caller to cache calls to this
/// if they want. This will also not resize the atlas if it is full.
///
/// IMPORTANT: this renders by /glyph index/ and not by /codepoint/. The caller
/// is expected to translate codepoints to glyph indexes in some way. The most
/// trivial way to do this is to get the Face and call glyphIndex. If you're
/// doing text shaping, the text shaping library (i.e. HarfBuzz) will automatically
/// determine glyph indexes for a text run.
pub fn renderGlyph(
    self: Group,
    alloc: Allocator,
    atlas: *Atlas,
    index: FontIndex,
    glyph_index: u32,
) !Glyph {
    const face = self.faces.get(index.style).items[@intCast(usize, index.idx)];
    return try face.renderGlyph(alloc, atlas, glyph_index);
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;
    const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc);
    defer group.deinit(alloc);

    try group.addFace(alloc, .regular, try Face.init(lib, testFont, .{ .points = 12 }));
    try group.addFace(alloc, .regular, try Face.init(lib, testEmoji, .{ .points = 12 }));

    // Should find all visible ASCII
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = group.indexForCodepoint(.regular, i).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);

        // Render it
        const face = group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex(i).?;
        _ = try group.renderGlyph(
            alloc,
            &atlas_greyscale,
            idx,
            glyph_index,
        );
    }

    // Try emoji
    {
        const idx = group.indexForCodepoint(.regular, '🥸').?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 1), idx.idx);
    }
}
