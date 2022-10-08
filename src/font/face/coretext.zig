const std = @import("std");
const assert = std.debug.assert;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");

pub const Face = struct {
    /// Our font face
    font: *macos.text.Font,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The presentation for this font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

    /// Initialize a CoreText-based font from a TTF/TTC in memory.
    pub fn init(lib: font.Library, source: [:0]const u8, size: font.face.DesiredSize) !Face {
        _ = lib;

        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const arr = macos.text.createFontDescriptorsFromData(data) orelse
            return error.FontInitFailure;
        defer arr.release();

        const desc = arr.getValueAtIndex(macos.text.FontDescriptor, 0);
        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
        defer ct_font.release();

        return try initFontCopy(ct_font, size);
    }

    /// Initialize a CoreText-based face from another initialized font face
    /// but with a new size. This is often how CoreText fonts are initialized
    /// because the font is loaded at a default size during discovery, and then
    /// adjusted to the final size for final load.
    pub fn initFontCopy(base: *macos.text.Font, size: font.face.DesiredSize) !Face {
        // Create a copy
        const ct_font = try base.copyWithAttributes(@intToFloat(f32, size.points), null);
        errdefer ct_font.release();

        const hb_font = try harfbuzz.coretext.createFont(ct_font);
        errdefer hb_font.destroy();

        const traits = ct_font.getSymbolicTraits();

        return Face{
            .font = ct_font,
            .hb_font = hb_font,
            .presentation = if (traits.color_glyphs) .emoji else .text,
            .metrics = calcMetrics(ct_font),
        };
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        // Turn UTF-32 into UTF-16 for CT API
        var unichars: [2]u16 = undefined;
        const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
        const len: usize = if (pair) 2 else 1;

        // Get our glyphs
        var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
        if (!self.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]))
            return null;

        // We can have pairs due to chars like emoji but we expect all of them
        // to decode down into exactly one glyph ID.
        if (pair) assert(glyphs[1] == 0);

        return @intCast(u32, glyphs[0]);
    }

    fn calcMetrics(ct_font: *macos.text.Font) font.face.Metrics {
        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        const cell_width: f32 = cell_width: {
            // Build a comptime array of all the ASCII chars
            const unichars = comptime unichars: {
                const len = 127 - 32;
                var result: [len]u16 = undefined;
                var i: u16 = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }

                break :unichars result;
            };

            // Get our glyph IDs for the ASCII chars
            var glyphs: [unichars.len]macos.graphics.Glyph = undefined;
            _ = ct_font.getGlyphsForCharacters(&unichars, &glyphs);

            // Get all our advances
            var advances: [unichars.len]macos.graphics.Size = undefined;
            _ = ct_font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

            // Find the maximum advance
            var max: f64 = 0;
            var i: usize = 0;
            while (i < advances.len) : (i += 1) {
                max = @maximum(advances[i].width, max);
            }

            break :cell_width @floatCast(f32, max);
        };

        std.log.warn("width={}", .{cell_width});
        return undefined;
    }
};

test {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 18 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        //_ = try face.renderGlyph(alloc, &atlas, ft_font.glyphIndex(i).?);
    }
}

test "emoji" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 18 });
    defer face.deinit();

    // Presentation
    try testing.expectEqual(font.Presentation.emoji, face.presentation);

    // Glyph index check
    try testing.expect(face.glyphIndex('🥸') != null);
}

test "in-memory" {
    const testing = std.testing;
    const testFont = @import("../test.zig").fontRegular;

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        //_ = try face.renderGlyph(alloc, &atlas, ft_font.glyphIndex(i).?);
    }
}
