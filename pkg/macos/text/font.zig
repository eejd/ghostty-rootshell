const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Font = opaque {
    pub fn createWithFontDescriptor(desc: *text.FontDescriptor, size: f32) Allocator.Error!*Font {
        return @intToPtr(
            ?*Font,
            @ptrToInt(c.CTFontCreateWithFontDescriptor(
                @ptrCast(c.CTFontDescriptorRef, desc),
                size,
                null,
            )),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Font) void {
        c.CFRelease(self);
    }

    pub fn getGlyphsForCharacters(self: *Font, chars: []const u16, glyphs: []graphics.Glyph) bool {
        assert(chars.len == glyphs.len);
        return c.CTFontGetGlyphsForCharacters(
            @ptrCast(c.CTFontRef, self),
            chars.ptr,
            glyphs.ptr,
            @intCast(c_long, chars.len),
        );
    }

    pub fn drawGlyphs(
        self: *Font,
        glyphs: []const graphics.Glyph,
        positions: []const graphics.Point,
        context: anytype, // Must be some context type from graphics
    ) void {
        assert(positions.len == glyphs.len);
        c.CTFontDrawGlyphs(
            @ptrCast(c.CTFontRef, self),
            glyphs.ptr,
            @ptrCast([*]const c.struct_CGPoint, positions.ptr),
            glyphs.len,
            @ptrCast(c.CGContextRef, context),
        );
    }

    pub fn getBoundingRectForGlyphs(
        self: *Font,
        orientation: FontOrientation,
        glyphs: []const graphics.Glyph,
        rects: ?[]graphics.Rect,
    ) graphics.Rect {
        if (rects) |s| assert(glyphs.len == s.len);
        return @bitCast(graphics.Rect, c.CTFontGetBoundingRectsForGlyphs(
            @ptrCast(c.CTFontRef, self),
            @enumToInt(orientation),
            glyphs.ptr,
            @ptrCast(?[*]c.struct_CGRect, if (rects) |s| s.ptr else null),
            @intCast(c_long, glyphs.len),
        ));
    }

    pub fn copyAttribute(self: *Font, comptime attr: text.FontAttribute) attr.Value() {
        return @intToPtr(attr.Value(), @ptrToInt(c.CTFontCopyAttribute(
            @ptrCast(c.CTFontRef, self),
            @ptrCast(c.CFStringRef, attr.key()),
        )));
    }

    pub fn copyDisplayName(self: *Font) *foundation.String {
        return @intToPtr(
            *foundation.String,
            @ptrToInt(c.CTFontCopyDisplayName(@ptrCast(c.CTFontRef, self))),
        );
    }
};

pub const FontOrientation = enum(c_uint) {
    default = c.kCTFontOrientationDefault,
    horizontal = c.kCTFontOrientationHorizontal,
    vertical = c.kCTFontOrientationVertical,
};

test {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    const font = try Font.createWithFontDescriptor(desc, 12);
    defer font.release();

    var glyphs = [1]graphics.Glyph{0};
    try testing.expect(font.getGlyphsForCharacters(
        &[_]u16{'A'},
        &glyphs,
    ));
    try testing.expect(glyphs[0] > 0);

    // Bounding rect
    {
        var rect = font.getBoundingRectForGlyphs(.horizontal, &glyphs, null);
        try testing.expect(rect.size.width > 0);

        var singles: [1]graphics.Rect = undefined;
        rect = font.getBoundingRectForGlyphs(.horizontal, &glyphs, &singles);
        try testing.expect(rect.size.width > 0);
        try testing.expect(singles[0].size.width > 0);
    }

    // Draw
    {
        const cs = try graphics.ColorSpace.createDeviceGray();
        defer cs.release();
        const ctx = try graphics.BitmapContext.create(null, 80, 80, 8, 80, cs);
        defer ctx.release();

        var pos = [_]graphics.Point{.{ .x = 0, .y = 0 }};
        font.drawGlyphs(
            &glyphs,
            &pos,
            ctx,
        );
    }
}
