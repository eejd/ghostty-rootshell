const std = @import("std");
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
        };
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.hb_font.destroy();
        self.* = undefined;
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

    try testing.expectEqual(font.Presentation.emoji, face.presentation);
}
