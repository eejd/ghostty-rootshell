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

    pub inline fn cval(self: *CharSet) *c.struct__FcCharSet {
        return @ptrCast(
            *c.struct__FcCharSet,
            self,
        );
    }
};

test "create" {
    var fs = CharSet.create();
    defer fs.destroy();
}
