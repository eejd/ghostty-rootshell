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
const BlockingQueue = @import("./blocking_queue.zig").BlockingQueue;
const renderer = @import("renderer.zig");

const log = std.log.scoped(.app);

const WindowList = std.ArrayListUnmanaged(*Window);

/// The type used for sending messages to the app thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// General purpose allocator
alloc: Allocator,

/// The list of windows that are currently open
windows: WindowList,

// The configuration for the app.
config: *const Config,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Set to true once we're quitting. This never goes false again.
quit: bool,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn create(alloc: Allocator, config: *const Config) !*App {
    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .windows = .{},
        .config = config,
        .mailbox = mailbox,
        .quit = false,
    };
    errdefer app.windows.deinit(alloc);

    // Create the first window
    try app.newWindow();

    return app;
}

pub fn destroy(self: *App) void {
    // Clean up all our windows
    for (self.windows.items) |window| window.destroy();
    self.windows.deinit(self.alloc);
    self.mailbox.destroy(self.alloc);
    self.alloc.destroy(self);
}

/// Wake up the app event loop. This should be called after any messages
/// are sent to the mailbox.
pub fn wakeup(self: App) void {
    _ = self;
    glfw.postEmptyEvent() catch {};
}

/// Run the main event loop for the application. This blocks until the
/// application quits or every window is closed.
pub fn run(self: *App) !void {
    while (!self.quit and self.windows.items.len > 0) {
        // Block for any glfw events.
        try glfw.waitEvents();

        // If any windows are closing, destroy them
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const window = self.windows.items[i];
            if (window.shouldClose()) {
                window.destroy();
                _ = self.windows.swapRemove(i);
                continue;
            }

            i += 1;
        }

        // Drain our mailbox only if we're not quitting.
        if (!self.quit) try self.drainMailbox();
    }
}

/// Drain the mailbox.
fn drainMailbox(self: *App) !void {
    var drain = self.mailbox.drain();
    defer drain.deinit();

    while (drain.next()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .new_window => try self.newWindow(),
            .quit => try self.setQuit(),
        }
    }
}

/// Create a new window
fn newWindow(self: *App) !void {
    var window = try Window.create(self.alloc, self, self.config);
    errdefer window.destroy();
    try self.windows.append(self.alloc, window);
    errdefer _ = self.windows.pop();
}

/// Start quitting
fn setQuit(self: *App) !void {
    if (self.quit) return;
    self.quit = true;

    // Mark that all our windows should close
    for (self.windows.items) |window| {
        window.window.setShouldClose(true);
    }
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    /// Create a new terminal window.
    new_window: void,

    /// Quit
    quit: void,
};
