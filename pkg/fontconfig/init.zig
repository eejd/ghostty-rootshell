const std = @import("std");
const c = @import("c.zig");

pub fn version() u32 {
    return @intCast(u32, c.FcGetVersion());
}

test "version" {
    const testing = std.testing;
    try testing.expect(version() > 0);
}
