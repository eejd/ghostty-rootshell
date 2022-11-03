//! The options that are used to configure a terminal IO implementation.

const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;

/// The size of the terminal grid.
grid_size: renderer.GridSize,

/// The size of the viewport in pixels.
screen_size: renderer.ScreenSize,

/// The app configuration.
config: *const Config,

/// The render state. The IO implementation can modify anything here. The
/// window thread will setup the initial "terminal" pointer but the IO impl
/// is free to change that if that is useful (i.e. doing some sort of dual
/// terminal implementation.)
renderer_state: *renderer.State,
