//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const Window = @import("Window.zig");
const libuv = @import("libuv");
const tracy = @import("tracy");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.app);

/// General purpose allocator
alloc: Allocator,

/// The primary window for the application. We currently support only
/// single window operations.
window: *Window,

// The main event loop for the application. The user data of this loop
// is always the allocator used to create the loop. This is a convenience
// so that users of the loop always have an allocator.
loop: libuv.Loop,

// The configuration for the app.
config: *const Config,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn init(alloc: Allocator, config: *const Config) !App {
    // Create the event loop
    var loop = try libuv.Loop.init(alloc);
    errdefer loop.deinit(alloc);

    // We always store allocator pointer on the loop data so that
    // handles can use our global allocator.
    const allocPtr = try alloc.create(Allocator);
    errdefer alloc.destroy(allocPtr);
    allocPtr.* = alloc;
    loop.setData(allocPtr);

    // Create the window
    var window = try Window.create(alloc, loop, config);
    errdefer window.destroy();

    return App{
        .alloc = alloc,
        .window = window,
        .loop = loop,
        .config = config,
    };
}

pub fn deinit(self: *App) void {
    self.window.destroy();

    // Run the loop one more time, because destroying our other things
    // like windows usually cancel all our event loop stuff and we need
    // one more run through to finalize all the closes.
    _ = self.loop.run(.default) catch |err|
        log.err("error finalizing event loop: {}", .{err});

    // Dealloc our allocator copy
    self.alloc.destroy(self.loop.getData(Allocator).?);

    self.loop.deinit(self.alloc);
    self.* = undefined;
}

pub fn run(self: App) !void {
    // We are embedding two event loops: glfw and libuv. To do this, we
    // create a separate thread that watches for libuv events and notifies
    // glfw to wake up so we can run the libuv tick.
    var embed = try libuv.Embed.init(self.alloc, self.loop, (struct {
        fn callback() void {
            glfw.postEmptyEvent() catch unreachable;
        }
    }).callback);
    defer embed.deinit(self.alloc);
    try embed.start();

    // This async handle is used to "wake up" the embed thread so we can
    // exit immediately once the windows want to close.
    var async_h = try libuv.Async.init(self.alloc, self.loop, (struct {
        fn callback(_: *libuv.Async) void {}
    }).callback);

    while (!self.window.shouldClose()) {
        // Block for any glfw events. This may also be an "empty" event
        // posted by the libuv watcher so that we trigger a libuv loop tick.
        try glfw.waitEvents();

        // Mark this so we're in a totally different "frame"
        tracy.frameMark();

        // Run the libuv loop
        const frame = tracy.frame("libuv");
        defer frame.end();
        try embed.loopRun();
    }

    // Notify the embed thread to stop. We do this before we send on the
    // async handle so that when the thread goes around it exits.
    embed.stop();

    // Wake up the event loop and schedule our close.
    try async_h.send();
    async_h.close((struct {
        fn callback(h: *libuv.Async) void {
            const alloc = h.loop().getData(Allocator).?.*;
            h.deinit(alloc);
        }
    }).callback);

    // Wait for the thread to end which should be almost instant.
    try embed.join();
}
