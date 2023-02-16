//! "apprt" is the "application runtime" package. This abstracts the
//! application runtime and lifecycle management such as creating windows,
//! getting user input (mouse/keyboard), etc.
//!
//! This enables compile-time interfaces to be built to swap out the underlying
//! application runtime. For example: glfw, pure macOS Cocoa, GTK+, browser, etc.
//!
//! The goal is to have different implementations share as much of the core
//! logic as possible, and to only reach out to platform-specific implementation
//! code when absolutely necessary.
const builtin = @import("builtin");
const build_config = @import("build_config.zig");

pub usingnamespace @import("apprt/structs.zig");
pub const glfw = @import("apprt/glfw.zig");
pub const browser = @import("apprt/browser.zig");
pub const embedded = @import("apprt/embedded.zig");
pub const Window = @import("apprt/Window.zig");

/// The implementation to use for the app runtime. This is comptime chosen
/// so that every build has exactly one application runtime implementation.
/// Note: it is very rare to use Runtime directly; most usage will use
/// Window or something.
pub const runtime = switch (build_config.artifact) {
    .exe => glfw,
    .lib => embedded,
    .wasm_module => browser,
};

test {
    @import("std").testing.refAllDecls(@This());
}
