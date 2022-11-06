//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const Window = @import("Window.zig");
const tracy = @import("tracy");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.app);

/// General purpose allocator
alloc: Allocator,

/// The primary window for the application. We currently support only
/// single window operations.
window: *Window,

// The configuration for the app.
config: *const Config,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn init(alloc: Allocator, config: *const Config) !App {
    // Create the window
    var window = try Window.create(alloc, config);
    errdefer window.destroy();

    return App{
        .alloc = alloc,
        .window = window,
        .config = config,
    };
}

pub fn deinit(self: *App) void {
    self.window.destroy();
    self.* = undefined;
}

pub fn run(self: App) !void {
    while (!self.window.shouldClose()) {
        // Block for any glfw events. This may also be an "empty" event
        // posted by the libuv watcher so that we trigger a libuv loop tick.
        try glfw.waitEvents();

        // Mark this so we're in a totally different "frame"
        tracy.frameMark();
    }
}
