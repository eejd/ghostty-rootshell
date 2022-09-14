const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");
const Pattern = @import("pattern.zig").Pattern;

pub const FontSet = opaque {
    pub fn create() *FontSet {
        return @ptrCast(*FontSet, c.FcFontSetCreate());
    }

    pub fn destroy(self: *FontSet) void {
        c.FcFontSetDestroy(self.cval());
    }

    pub fn len(self: *FontSet) u32 {
        return @intCast(u32, self.cval().nfont);
    }

    pub fn get(self: *FontSet, idx: usize) *Pattern {
        assert(idx < self.len());
        return @ptrCast(*Pattern, self.cval().fonts[idx]);
    }

    pub inline fn cval(self: *FontSet) *c.struct__FcFontSet {
        return @ptrCast(
            *c.struct__FcFontSet,
            @alignCast(@alignOf(c.struct__FcFontSet), self),
        );
    }
};

test "create" {
    const testing = std.testing;

    var fs = FontSet.create();
    defer fs.destroy();

    try testing.expectEqual(@as(u32, 0), fs.len());
}
