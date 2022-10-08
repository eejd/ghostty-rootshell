const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig");

pub const ColorSpace = opaque {
    pub fn createDeviceGray() Allocator.Error!*ColorSpace {
        return @intToPtr(
            ?*ColorSpace,
            @ptrToInt(c.CGColorSpaceCreateDeviceGray()),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *ColorSpace) void {
        c.CGColorSpaceRelease(@ptrCast(c.CGColorSpaceRef, self));
    }
};

test {
    //const testing = std.testing;

    const space = try ColorSpace.createDeviceGray();
    defer space.release();
}
