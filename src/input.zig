const std = @import("std");
const builtin = @import("builtin");

pub usingnamespace @import("input/mouse.zig");
pub usingnamespace @import("input/key.zig");
pub const keycodes = @import("input/keycodes.zig");
pub const Binding = @import("input/Binding.zig");
pub const SplitDirection = Binding.Action.SplitDirection;
pub const SplitFocusDirection = Binding.Action.SplitFocusDirection;

// Keymap is only available on macOS right now
pub const Keymap = switch (builtin.os.tag) {
    .macos => @import("input/Keymap.zig"),
    else => struct {},
};

test {
    std.testing.refAllDecls(@This());
}
