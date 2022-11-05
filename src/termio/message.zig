const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to an IO thread.
pub const IO = union(enum) {
    /// Resize the window.
    resize: struct {
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    },

    /// Clear the selection
    clear_selection: void,
    //
    // /// Scroll the viewport
    // scroll_viewport: terminal.Terminal.ScrollViewport,
};
