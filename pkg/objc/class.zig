const std = @import("std");
const c = @import("c.zig");

pub const Class = struct {
    value: c.Class,

    /// Returns the class definition of a specified class.
    pub fn getClass(name: [:0]const u8) ?Class {
        return Class{
            .value = c.objc_getClass(name.ptr) orelse return null,
        };
    }
};

test {
    const testing = std.testing;
    const NSObject = Class.getClass("NSObject");
    try testing.expect(NSObject != null);
    try testing.expect(Class.getClass("NoWay") == null);
}
