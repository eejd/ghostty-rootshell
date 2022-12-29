//! Window implementation and utilities. The window subsystem is responsible
//! for maintaining a "window" or "surface" abstraction around a terminal,
//! effectively being the primary interface to the terminal.

const builtin = @import("builtin");

pub usingnamespace @import("window/structs.zig");
pub const Glfw = @import("window/Glfw.zig");

/// The implementation to use for the windowing system. This is comptime chosen
/// so that every build has exactly one windowing implementation.
pub const System = switch (builtin.os.tag) {
    else => Glfw,
};

test {
    @import("std").testing.refAllDecls(@This());
}
