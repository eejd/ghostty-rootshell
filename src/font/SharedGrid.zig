//! This structure represents the state required to render a terminal
//! grid using the font subsystem. It is "shared" because it is able to
//! be shared across multiple surfaces.
//!
//! It is desirable for the grid state to be shared because the font
//! configuration for a set of surfaces is almost always the same and
//! font data is relatively memory intensive. Further, the font subsystem
//! should be read-heavy compared to write-heavy, so it handles concurrent
//! reads well. Going even further, the font subsystem should be very rarely
//! read at all since it should only be necessary when the grid actively
//! changes.
//!
//! SharedGrid does NOT support resizing, font-family changes, font removals
//! in collections, etc. Because the Grid is shared this would cause a
//! major disruption in the rendering of multiple surfaces (i.e. increasing
//! the font size in one would increase it in all). In many cases this isn't
//! desirable so to implement configuration changes the grid should be
//! reinitialized and all surfaces should switch over to using that one.
const SharedGrid = @This();

// TODO(fontmem):
// - consider config changes and how they affect the shared grid.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("main.zig");
const Atlas = font.Atlas;
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Face = font.Face;
const Glyph = font.Glyph;
const Library = font.Library;
const Metrics = font.face.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;
const RenderOptions = font.face.RenderOptions;

const log = std.log.scoped(.font_shared_grid);

/// Cache for codepoints to font indexes in a group.
codepoints: std.AutoHashMapUnmanaged(CodepointKey, ?Collection.Index) = .{},

/// Cache for glyph renders into the atlas.
glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .{},

/// The texture atlas to store renders in. The Glyph data in the glyphs
/// cache is dependent on the atlas matching.
atlas_greyscale: Atlas,
atlas_color: Atlas,

/// The underlying resolver for font data, fallbacks, etc. The shared
/// grid takes ownership of the resolver and will free it.
resolver: CodepointResolver,

/// The currently active grid metrics dictating the layout of the grid.
/// This is calculated based on the resolver and current fonts.
metrics: Metrics,

/// The RwLock used to protect the shared grid.
lock: std.Thread.RwLock,

/// Initialize the grid.
///
/// The resolver must have a collection that supports deferred loading
/// (collection.load_options != null). This is because we need the load
/// options data to determine grid metrics and setup our sprite font.
///
/// SharedGrid always configures the sprite font. This struct is expected to be
/// used with a terminal grid and therefore the sprite font is always
/// necessary for correct rendering.
pub fn init(
    alloc: Allocator,
    resolver: CodepointResolver,
    thicken: bool,
) !SharedGrid {
    // We need to support loading options since we use the size data
    assert(resolver.collection.load_options != null);

    var atlas_greyscale = try Atlas.init(alloc, 512, .greyscale);
    errdefer atlas_greyscale.deinit(alloc);
    var atlas_color = try Atlas.init(alloc, 512, .rgba);
    errdefer atlas_color.deinit(alloc);

    var result: SharedGrid = .{
        .resolver = resolver,
        .atlas_greyscale = atlas_greyscale,
        .atlas_color = atlas_color,
        .lock = .{},
        .metrics = undefined, // Loaded below
    };

    // We set an initial capacity that can fit a good number of characters.
    // This number was picked empirically based on my own terminal usage.
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    try result.glyphs.ensureTotalCapacity(alloc, 128);

    // Initialize our metrics.
    try result.reloadMetrics(thicken);

    return result;
}

/// Deinit. Assumes no concurrent access so no lock is taken.
pub fn deinit(self: *SharedGrid, alloc: Allocator) void {
    self.codepoints.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.atlas_greyscale.deinit(alloc);
    self.atlas_color.deinit(alloc);
    self.resolver.deinit(alloc);
}

fn reloadMetrics(self: *SharedGrid, thicken: bool) !void {
    // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
    // Doesn't matter, any normal ASCII will do we're just trying to make
    // sure we use the regular font.
    // We don't go through our caching layer because we want to minimize
    // possible failures.
    const collection = &self.resolver.collection;
    const index = collection.getIndex('M', .regular, .{ .any = {} }).?;
    const face = try collection.getFace(index);
    self.metrics = face.metrics;

    // Setup our sprite font.
    self.resolver.sprite = .{
        .width = self.metrics.cell_width,
        .height = self.metrics.cell_height,
        .thickness = self.metrics.underline_thickness *
            @as(u32, if (thicken) 2 else 1),
        .underline_position = self.metrics.underline_position,
    };
}

const CodepointKey = struct {
    style: Style,
    codepoint: u32,
    presentation: ?Presentation,
};

const GlyphKey = struct {
    index: Collection.Index,
    glyph: u32,
    opts: RenderOptions,
};

const TestMode = enum { normal };

fn testGrid(mode: TestMode, alloc: Allocator, lib: Library) !SharedGrid {
    const testFont = @import("test.zig").fontRegular;

    var c = try Collection.init(alloc);
    c.load_options = .{ .library = lib };

    switch (mode) {
        .normal => {
            _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
                lib,
                testFont,
                .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
            ) });
        },
    }

    var r: CodepointResolver = .{ .collection = c };
    errdefer r.deinit(alloc);

    return try init(alloc, r, false);
}

test "SharedGrid inits metrics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // const testEmoji = @import("test.zig").fontEmoji;

    var lib = try Library.init();
    defer lib.deinit();

    var grid = try testGrid(.normal, alloc, lib);
    defer grid.deinit(alloc);

    // Visible ASCII. Do it twice to verify cache is used.
    // var i: u32 = 32;
    // while (i < 127) : (i += 1) {
    //     const idx = (try cache.indexForCodepoint(alloc, i, .regular, null)).?;
    //     try testing.expectEqual(Style.regular, idx.style);
    //     try testing.expectEqual(@as(Group.FontIndex.IndexInt, 0), idx.idx);
    //
    //     // Render
    //     const face = try cache.group.faceFromIndex(idx);
    //     const glyph_index = face.glyphIndex(i).?;
    //     _ = try cache.renderGlyph(
    //         alloc,
    //         idx,
    //         glyph_index,
    //         .{},
    //     );
    // }
}
