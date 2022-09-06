//! A glyph cache sits on top of a Group and caches the results from it.
const GroupCache = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Atlas = @import("../Atlas.zig");
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;
const Group = @import("main.zig").Group;
const Metrics = @import("main.zig").Metrics;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.font_groupcache);

/// Cache for codepoints to font indexes in a group.
codepoints: std.AutoHashMapUnmanaged(CodepointKey, ?Group.FontIndex) = .{},

/// Cache for glyph renders.
glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .{},

/// The underlying font group. Users are expected to use this directly
/// to setup the group or make changes. Beware some changes require a reset
/// (see reset).
group: Group,

/// The texture atlas to store renders in. The GroupCache has to store these
/// because the cached Glyph result is dependent on the Atlas.
atlas_greyscale: Atlas,
atlas_color: Atlas,

const CodepointKey = struct {
    style: Style,
    codepoint: u32,
    presentation: ?Presentation,
};

const GlyphKey = struct {
    index: Group.FontIndex,
    glyph: u32,
};

/// The GroupCache takes ownership of Group and will free it.
pub fn init(alloc: Allocator, group: Group) !GroupCache {
    var atlas_greyscale = try Atlas.init(alloc, 512, .greyscale);
    errdefer atlas_greyscale.deinit(alloc);
    var atlas_color = try Atlas.init(alloc, 512, .rgba);
    errdefer atlas_color.deinit(alloc);

    var result: GroupCache = .{
        .group = group,
        .atlas_greyscale = atlas_greyscale,
        .atlas_color = atlas_color,
    };

    // We set an initial capacity that can fit a good number of characters.
    // This number was picked empirically based on my own terminal usage.
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    try result.glyphs.ensureTotalCapacity(alloc, 128);

    return result;
}

pub fn deinit(self: *GroupCache, alloc: Allocator) void {
    self.codepoints.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.atlas_greyscale.deinit(alloc);
    self.atlas_color.deinit(alloc);
    self.group.deinit(alloc);
}

/// Reset the cache. This should be called:
///
///   - If an Atlas was reset
///   - If a font group font size was changed
///   - If a font group font set was changed
///
pub fn reset(self: *GroupCache) void {
    self.codepoints.clearRetainingCapacity();
    self.glyphs.clearRetainingCapacity();
}

/// Calculate the metrics for this group. This also warms the cache
/// since this preloads all the ASCII characters.
pub fn metrics(self: *GroupCache, alloc: Allocator) !Metrics {
    // Load all visible ASCII characters and build our cell width based on
    // the widest character that we see.
    const cell_width: f32 = cell_width: {
        var cell_width: f32 = 0;
        var i: u32 = 32;
        while (i <= 126) : (i += 1) {
            const index = (try self.indexForCodepoint(alloc, i, .regular, .text)).?;
            const face = self.group.faceFromIndex(index);
            const glyph_index = face.glyphIndex(i).?;
            const glyph = try self.renderGlyph(alloc, index, glyph_index);
            if (glyph.advance_x > cell_width) {
                cell_width = @ceil(glyph.advance_x);
            }
        }

        break :cell_width cell_width;
    };

    // The cell height is the vertical height required to render underscore
    // '_' which should live at the bottom of a cell.
    const cell_height: f32 = cell_height: {
        // Get the '_' char for height
        const index = (try self.indexForCodepoint(alloc, '_', .regular, .text)).?;
        const face = self.group.faceFromIndex(index);
        const glyph_index = face.glyphIndex('_').?;
        const glyph = try self.renderGlyph(alloc, index, glyph_index);

        // This is the height reported by the font face
        const face_height: i32 = face.unitsToPxY(face.face.handle.*.height);

        // Determine the height of the underscore char
        var res: i32 = face.unitsToPxY(face.face.handle.*.ascender);
        res -= glyph.offset_y;
        res += @intCast(i32, glyph.height);

        // We take whatever is larger to account for some fonts that
        // put the underscore outside f the rectangle.
        if (res < face_height) res = face_height;

        break :cell_height @intToFloat(f32, res);
    };

    const cell_baseline = cell_baseline: {
        const face = self.group.faces.get(.regular).items[0];
        break :cell_baseline cell_height - @intToFloat(
            f32,
            face.unitsToPxY(face.face.handle.*.ascender),
        );
    };

    return Metrics{
        .cell_width = cell_width,
        .cell_height = cell_height,
        .cell_baseline = cell_baseline,
    };
}

/// Get the font index for a given codepoint. This is cached.
pub fn indexForCodepoint(
    self: *GroupCache,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) !?Group.FontIndex {
    const key: CodepointKey = .{ .style = style, .codepoint = cp, .presentation = p };
    const gop = try self.codepoints.getOrPut(alloc, key);

    // If it is in the cache, use it.
    if (gop.found_existing) return gop.value_ptr.*;

    // Load a value and cache it. This even caches negative matches.
    const value = self.group.indexForCodepoint(cp, style, null);
    gop.value_ptr.* = value;
    return value;
}

/// Render a glyph. This automatically determines the correct texture
/// atlas to use and caches the result.
pub fn renderGlyph(
    self: *GroupCache,
    alloc: Allocator,
    index: Group.FontIndex,
    glyph_index: u32,
) !Glyph {
    const key: GlyphKey = .{ .index = index, .glyph = glyph_index };
    const gop = try self.glyphs.getOrPut(alloc, key);

    // If it is in the cache, use it.
    if (gop.found_existing) return gop.value_ptr.*;

    // Uncached, render it
    const face = self.group.faceFromIndex(index);
    const atlas: *Atlas = if (face.hasColor()) &self.atlas_color else &self.atlas_greyscale;
    const glyph = self.group.renderGlyph(
        alloc,
        atlas,
        index,
        glyph_index,
    ) catch |err| switch (err) {
        // If the atlas is full, we resize it
        error.AtlasFull => blk: {
            try atlas.grow(alloc, atlas.size * 2);
            break :blk try self.group.renderGlyph(
                alloc,
                atlas,
                index,
                glyph_index,
            );
        },

        else => return err,
    };

    // Cache and return
    gop.value_ptr.* = glyph;
    return glyph;
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;
    // const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var cache = try init(alloc, try Group.init(alloc));
    defer cache.deinit(alloc);

    // Setup group
    try cache.group.addFace(alloc, .regular, try Face.init(lib, testFont, .{ .points = 12 }));
    const group = cache.group;

    // Visible ASCII. Do it twice to verify cache.
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = (try cache.indexForCodepoint(alloc, i, .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Group.FontIndex.IndexInt, 0), idx.idx);

        // Render
        const face = cache.group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex(i).?;
        _ = try cache.renderGlyph(
            alloc,
            idx,
            glyph_index,
        );
    }

    // Do it again, but reset the group so that we know for sure its not hitting it
    {
        cache.group = undefined;
        defer cache.group = group;

        i = 32;
        while (i < 127) : (i += 1) {
            const idx = (try cache.indexForCodepoint(alloc, i, .regular, null)).?;
            try testing.expectEqual(Style.regular, idx.style);
            try testing.expectEqual(@as(Group.FontIndex.IndexInt, 0), idx.idx);

            // Render
            const face = group.faceFromIndex(idx);
            const glyph_index = face.glyphIndex(i).?;
            _ = try cache.renderGlyph(
                alloc,
                idx,
                glyph_index,
            );
        }
    }
}
