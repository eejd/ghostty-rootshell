//! The options that are used to configure a renderer.

const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");

/// The font group that should be used.
font_group: *font.GroupCache,

/// Padding options for the viewport.
padding: Padding,

pub const Padding = struct {
    // Explicit padding options, in pixels. The windowing thread is
    // expected to convert points to pixels for a given DPI.
    explicit: renderer.Padding,

    // Balance options
    balance: bool = false,
};
