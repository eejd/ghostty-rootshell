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
}
