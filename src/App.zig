//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const build_config = @import("build_config.zig");
const apprt = @import("apprt.zig");
const Window = @import("Window.zig");
const tracy = @import("tracy");
const Config = @import("config.zig").Config;
const BlockingQueue = @import("./blocking_queue.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const macos = @import("macos");
const objc = @import("objc");
const DevMode = @import("DevMode.zig");

const log = std.log.scoped(.app);

const WindowList = std.ArrayListUnmanaged(*Window);

/// The type used for sending messages to the app thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// General purpose allocator
alloc: Allocator,

/// The runtime for this app.
runtime: apprt.runtime.App,

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

/// Mac-specific settings. This is only enabled when the target is
/// Mac and the artifact is a standalone exe. We don't target libs because
/// the embedded API doesn't do windowing.
pub const Darwin = struct {
    pub const enabled = builtin.target.isDarwin() and build_config.artifact == .exe;

    tabbing_id: *macos.foundation.String,

    pub fn deinit(self: *Darwin) void {
        self.tabbing_id.release();
        self.* = undefined;
    }
};

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn create(
    alloc: Allocator,
    rt_opts: apprt.runtime.App.Options,
    config: *const Config,
) !*App {
    // Initialize app runtime
    var app_backend = try apprt.runtime.App.init(rt_opts);
    errdefer app_backend.terminate();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // If we have DevMode on, store the config so we can show it
    if (DevMode.enabled) DevMode.instance.config = config;

    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .runtime = app_backend,
        .windows = .{},
        .config = config,
        .mailbox = mailbox,
        .quit = false,
        .darwin = if (Darwin.enabled) undefined else {},
    };
    errdefer app.windows.deinit(alloc);

    // On Mac, we enable window tabbing. We only do this if we're building
    // a standalone exe. In embedded mode the host app handles this for us.
    if (Darwin.enabled) {
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

    // Create the first window if we're an executable. If we're a lib we
    // do NOT create the first window because we expect the embedded API
    // to do it via surfaces.
    if (build_config.artifact == .exe) {
        _ = try app.newWindow(.{});
    }

    return app;
}

pub fn destroy(self: *App) void {
    // Clean up all our windows
    for (self.windows.items) |window| window.destroy();
    self.windows.deinit(self.alloc);
    if (Darwin.enabled) self.darwin.deinit();
    self.mailbox.destroy(self.alloc);
    self.alloc.destroy(self);

    // Close our windowing runtime
    self.runtime.terminate();
}

/// Wake up the app event loop. This should be called after any messages
/// are sent to the mailbox.
pub fn wakeup(self: App) void {
    self.runtime.wakeup() catch return;
}

/// Run the main event loop for the application. This blocks until the
/// application quits or every window is closed.
pub fn run(self: *App) !void {
    while (!self.quit and self.windows.items.len > 0) {
        // Block for any events.
        try self.runtime.wait();

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
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .new_window => |msg| _ = try self.newWindow(msg),
            .new_tab => |msg| try self.newTab(msg),
            .quit => try self.setQuit(),
            .window_message => |msg| try self.windowMessage(msg.window, msg.message),
        }
    }
}

/// Create a new window
fn newWindow(self: *App, msg: Message.NewWindow) !*Window {
    var window = try Window.create(self.alloc, self, self.config);
    errdefer window.destroy();
    try self.windows.append(self.alloc, window);
    errdefer _ = self.windows.pop();

    // Set initial font size if given
    if (msg.font_size) |size| window.setFontSize(size);

    return window;
}

/// Create a new tab in the parent window
fn newTab(self: *App, msg: Message.NewWindow) !void {
    if (comptime !builtin.target.isDarwin()) {
        log.warn("tabbing is not supported on this platform", .{});
        return;
    }

    const parent = msg.parent orelse {
        log.warn("parent must be set in new_tab message", .{});
        return;
    };

    // If the parent was closed prior to us handling the message, we do nothing.
    if (!self.hasWindow(parent)) {
        log.warn("new_tab parent is gone, not launching a new tab", .{});
        return;
    }

    // Create the new window
    const window = try self.newWindow(msg);

    // Add the window to our parent tab group
    parent.addWindow(window);
}

/// Start quitting
fn setQuit(self: *App) !void {
    if (self.quit) return;
    self.quit = true;

    // Mark that all our windows should close
    for (self.windows.items) |window| {
        window.window.setShouldClose();
    }
}

/// Handle a window message
fn windowMessage(self: *App, win: *Window, msg: Window.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasWindow(win)) {
        try win.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasWindow(self: *App, win: *Window) bool {
    for (self.windows.items) |window| {
        if (window == win) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    /// Create a new terminal window.
    new_window: NewWindow,

    /// Create a new tab within the tab group of the focused window.
    /// This does nothing if we're on a platform or using a window
    /// environment that doesn't support tabs.
    new_tab: NewWindow,

    /// Quit
    quit: void,

    /// A message for a specific window
    window_message: struct {
        window: *Window,
        message: Window.Message,
    },

    const NewWindow = struct {
        /// The parent window, only used for new tabs.
        parent: ?*Window = null,

        /// The font size to create the window with or null to default to
        /// the configuration amount.
        font_size: ?font.face.DesiredSize = null,
    };
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};

// C API
pub const CAPI = struct {
    const global = &@import("main.zig").state;

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const app = try App.create(global.alloc, opts.*, config);
        errdefer app.destroy();
        return app;
    }

    export fn ghostty_app_free(ptr: ?*App) void {
        if (ptr) |v| {
            v.destroy();
            v.alloc.destroy(v);
        }
    }
};
