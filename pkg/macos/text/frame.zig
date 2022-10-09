const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Frame = opaque {
    pub fn release(self: *Frame) void {
        foundation.CFRelease(self);
    }

    pub fn getLineOrigins(
        self: *Frame,
        range: foundation.Range,
        points: []graphics.Point,
    ) void {
        c.CTFrameGetLineOrigins(
            @ptrCast(c.CTFrameRef, self),
            @bitCast(c.CFRange, range),
            @ptrCast(*c.CGPoint, points.ptr),
        );
    }
};

test {
    // See framesetter tests...
}
