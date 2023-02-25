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
const Surface = @import("Surface.zig");
const tracy = @import("tracy");
const input = @import("input.zig");
const Config = @import("config.zig").Config;
const BlockingQueue = @import("./blocking_queue.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const macos = @import("macos");
const objc = @import("objc");
const DevMode = @import("DevMode.zig");

const log = std.log.scoped(.app);

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

// The configuration for the app.
config: *const Config,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// Set to true once we're quitting. This never goes false again.
quit: bool,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn create(
    alloc: Allocator,
    config: *const Config,
) !*App {
    // If we have DevMode on, store the config so we can show it
    if (DevMode.enabled) DevMode.instance.config = config;

    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .surfaces = .{},
        .config = config,
        .mailbox = .{},
        .quit = false,
    };
    errdefer app.surfaces.deinit(alloc);

    return app;
}

pub fn destroy(self: *App) void {
    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    self.alloc.destroy(self);
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
///
/// This returns whether the app should quit or not.
pub fn tick(self: *App, rt_app: *apprt.App) !bool {
    // If any surfaces are closing, destroy them
    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        const surface = self.surfaces.items[i];
        if (surface.shouldClose()) {
            rt_app.closeSurface(surface);
            continue;
        }

        i += 1;
    }

    // Drain our mailbox only if we're not quitting.
    if (!self.quit) try self.drainMailbox(rt_app);

    // We quit if our quit flag is on or if we have closed all surfaces.
    return self.quit or self.surfaces.items.len == 0;
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
pub fn addSurface(self: *App, rt_surface: *apprt.Surface) !void {
    try self.surfaces.append(self.alloc, rt_surface);
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }

        i += 1;
    }
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| try self.closeSurface(rt_app, surface),
            .quit => try self.setQuit(),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .redraw_surface => |surface| try self.redrawSurface(rt_app, surface),
        }
    }
}

fn closeSurface(self: *App, rt_app: *apprt.App, surface: *Surface) !void {
    if (!self.hasSurface(surface)) return;
    rt_app.closeSurface(surface.rt_surface);
}

fn redrawSurface(self: *App, rt_app: *apprt.App, surface: *apprt.Surface) !void {
    if (!self.hasSurface(&surface.core_surface)) return;
    rt_app.redrawSurface(surface);
}

/// Create a new window
fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    if (!@hasDecl(apprt.App, "newWindow")) {
        log.warn("newWindow is not supported by this runtime", .{});
        return;
    }

    const parent = if (msg.parent) |parent| parent: {
        break :parent if (self.hasSurface(parent))
            parent
        else
            null;
    } else null;

    try rt_app.newWindow(parent);
}

/// Start quitting
fn setQuit(self: *App) !void {
    if (self.quit) return;
    self.quit = true;

    // Mark that all our surfaces should close
    for (self.surfaces.items) |surface| {
        surface.setShouldClose();
    }
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasSurface(self: *App, surface: *Surface) bool {
    for (self.surfaces.items) |v| {
        if (&v.core_surface == surface) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    /// Create a new terminal window.
    new_window: NewWindow,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// Redraw a surface. This only has an effect for runtimes that
    /// use single-threaded draws. To redraw a surface for all runtimes,
    /// wake up the renderer thread. The renderer thread will send this
    /// message if it needs to.
    redraw_surface: *apprt.Surface,

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,
    };
};

/// Mailbox is the way that other threads send the app thread messages.
pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
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
