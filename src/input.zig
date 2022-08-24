const std = @import("std");

pub usingnamespace @import("input/key.zig");
pub const Binding = @import("input/Binding.zig");

test {
    std.testing.refAllDecls(@This());
}
