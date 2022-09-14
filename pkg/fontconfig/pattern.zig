const std = @import("std");
const c = @import("c.zig");

pub const Pattern = opaque {
    pub fn create() *Pattern {
        return @ptrCast(*Pattern, c.FcPatternCreate());
    }

    pub fn parse(str: [:0]const u8) *Pattern {
        return @ptrCast(*Pattern, c.FcNameParse(str.ptr));
    }

    pub fn destroy(self: *Pattern) void {
        c.FcPatternDestroy(@ptrCast(
            *c.struct__FcPattern,
            self,
        ));
    }
};

test "create" {
    var pat = Pattern.create();
    defer pat.destroy();
}

test "name parse" {
    var pat = Pattern.parse(":monospace");
    defer pat.destroy();
}
