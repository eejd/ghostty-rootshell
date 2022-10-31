const terminal = @import("../terminal/main.zig");

/// Available cursor styles for drawing that renderers must support.
pub const CursorStyle = enum {
    box,
    box_hollow,
    bar,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(style: terminal.CursorStyle) ?CursorStyle {
        return switch (style) {
            .blinking_block, .steady_block => .box,
            .blinking_bar, .steady_bar => .bar,
            .blinking_underline, .steady_underline => null, // TODO
            .default => .box,
            else => null,
        };
    }
};
