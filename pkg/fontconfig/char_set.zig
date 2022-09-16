const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const CharSet = opaque {
    pub fn create() *CharSet {
        return @ptrCast(*CharSet, c.FcCharSetCreate());
    }

    pub fn destroy(self: *CharSet) void {
        c.FcCharSetDestroy(self.cval());
    }

    pub fn hasChar(self: *CharSet, cp: u32) bool {
        return c.FcCharSetHasChar(self.cval(), cp) == c.FcTrue;
    }

    pub inline fn cval(self: *CharSet) *c.struct__FcCharSet {
        return @ptrCast(
            *c.struct__FcCharSet,
            self,
        );
    }
};

test "create" {
    const testing = std.testing;

    var fs = CharSet.create();
    defer fs.destroy();

    try testing.expect(!fs.hasChar(0x20));
}
