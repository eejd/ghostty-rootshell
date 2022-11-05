const std = @import("std");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to an IO thread.
pub const IO = union(enum) {
    pub const SmallWriteArray = [22]u8;

    /// Resize the window.
    resize: struct {
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    },

    /// Clear the selection
    clear_selection: void,

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Write where the data fits in the union.
    small_write: struct {
        data: [22]u8,
        len: u8,
    },
};

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 24), @sizeOf(IO));
}
