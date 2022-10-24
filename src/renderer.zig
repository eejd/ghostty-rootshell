//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

pub usingnamespace @import("renderer/size.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
