//! The options that are used to configure a terminal IO implementation.

const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;

/// The size of the terminal grid.
grid_size: renderer.GridSize,

/// The size of the viewport in pixels.
screen_size: renderer.ScreenSize,

/// The app configuration.
config: *const Config,
