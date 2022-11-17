//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const Window = @import("Window.zig");
const tracy = @import("tracy");
const Config = @import("config.zig").Config;
const BlockingQueue = @import("./blocking_queue.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const macos = @import("macos");
const objc = @import("objc");

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

/// Mac settings
darwin: if (Darwin.enabled) Darwin else void,

/// Mac-specific settings
pub const Darwin = struct {
    pub const enabled = builtin.target.isDarwin();

    tabbing_id: *macos.foundation.String,

    pub fn deinit(self: *Darwin) void {
        self.tabbing_id.release();
        self.* = undefined;
    }
};

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
        .darwin = if (Darwin.enabled) undefined else {},
    };
    errdefer app.windows.deinit(alloc);

    // On Mac, we enable window tabbing
    if (comptime builtin.target.isDarwin()) {
        const NSWindow = objc.Class.getClass("NSWindow").?;
        NSWindow.msgSend(void, objc.sel("setAllowsAutomaticWindowTabbing:"), .{true});

        // Our tabbing ID allows all of our windows to group together
        const tabbing_id = try macos.foundation.String.createWithBytes(
            "dev.ghostty.window",
            .utf8,
            false,
        );
        errdefer tabbing_id.release();

        // Setup our Mac settings
        app.darwin = .{
            .tabbing_id = tabbing_id,
        };
    }
    errdefer if (comptime builtin.target.isDarwin()) app.darwin.deinit();

    // Create the first window
    try app.newWindow(.{});

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
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .new_window => |msg| try self.newWindow(msg),
            .quit => try self.setQuit(),
            .window_message => |msg| try self.windowMessage(msg.window, msg.message),
        }
    }
}

/// Create a new window
fn newWindow(self: *App, msg: Message.NewWindow) !void {
    var window = try Window.create(self.alloc, self, self.config);
    errdefer window.destroy();
    try self.windows.append(self.alloc, window);
    errdefer _ = self.windows.pop();

    // Set initial font size if given
    if (msg.font_size) |size| window.setFontSize(size);
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

/// Handle a window message
fn windowMessage(self: *App, win: *Window, msg: Window.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    for (self.windows.items) |window| {
        if (window == win) {
            try win.handleMessage(msg);
            return;
        }
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    /// Create a new terminal window.
    new_window: NewWindow,

    /// Quit
    quit: void,

    /// A message for a specific window
    window_message: struct {
        window: *Window,
        message: Window.Message,
    },

    const NewWindow = struct {
        /// The font size to create the window with or null to default to
        /// the configuration amount.
        font_size: ?font.face.DesiredSize = null,
    };
};
