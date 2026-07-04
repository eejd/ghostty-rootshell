const std = @import("std");
const lib = @import("../lib.zig");
const unicode_pkg = @import("../../unicode/main.zig");

pub fn codepoint_width(cp: u32) callconv(lib.calling_conv) u8 {
    if (cp > 0x10FFFF) return 1;
    return unicode_pkg.codepointWidth(@intCast(cp));
}

test "codepoint_width narrow" {
    const testing = std.testing;
    try testing.expectEqual(1, codepoint_width('a'));
}

test "codepoint_width wide" {
    const testing = std.testing;
    try testing.expectEqual(2, codepoint_width(0x4E00));
}

test "codepoint_width zero" {
    const testing = std.testing;
    try testing.expectEqual(0, codepoint_width(0x0301));
}

test "codepoint_width out of range" {
    const testing = std.testing;
    try testing.expectEqual(1, codepoint_width(0x110000));
    try testing.expectEqual(1, codepoint_width(std.math.maxInt(u32)));
}
