const std = @import("std");

pub usingnamespace @import("input/mouse.zig");
pub usingnamespace @import("input/key.zig");
pub const Binding = @import("input/Binding.zig");
pub const SplitDirection = Binding.Action.SplitDirection;

test {
    std.testing.refAllDecls(@This());
}
