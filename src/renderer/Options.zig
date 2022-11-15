//! The options that are used to configure a renderer.

const font = @import("../font/main.zig");

/// The font group that should be used.
font_group: *font.GroupCache,

/// Padding options for the viewport.
padding: Padding,

pub const Padding = struct {
    // Explicit padding options, in pixels. The windowing thread is
    // expected to convert points to pixels for a given DPI.
    top: u32 = 0,
    bottom: u32 = 0,
    right: u32 = 0,
    left: u32 = 0,

    // Balance options
    balance: bool = false,
};
