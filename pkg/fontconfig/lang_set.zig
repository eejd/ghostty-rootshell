const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const LangSet = opaque {
    pub fn create() *LangSet {
        return @ptrCast(*LangSet, c.FcLangSetCreate());
    }

    pub fn destroy(self: *LangSet) void {
        c.FcLangSetDestroy(self.cval());
    }

    pub inline fn cval(self: *LangSet) *c.struct__FcLangSet {
        return @ptrCast(
            *c.struct__FcLangSet,
            self,
        );
    }
};

test "create" {
    var fs = LangSet.create();
    defer fs.destroy();
}
