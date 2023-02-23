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

/// The type used for sending messages to the app thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

// The configuration for the app.
config: *const Config,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Set to true once we're quitting. This never goes false again.
quit: bool,

/// App will call this when tick should be called.
wakeup_cb: ?*const fn () void = null,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn create(
    alloc: Allocator,
    config: *const Config,
) !*App {
    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // If we have DevMode on, store the config so we can show it
    if (DevMode.enabled) DevMode.instance.config = config;

    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .surfaces = .{},
        .config = config,
        .mailbox = mailbox,
        .quit = false,
    };
    errdefer app.surfaces.deinit(alloc);

    return app;
}

pub fn destroy(self: *App) void {
    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);
    self.mailbox.destroy(self.alloc);

    self.alloc.destroy(self);
}

/// Request the app runtime to process app events via tick.
pub fn wakeup(self: App) void {
    if (self.wakeup_cb) |cb| cb();
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
///
/// This returns whether the app should quit or not.
pub fn tick(self: *App, rt_app: *apprt.runtime.App) !bool {
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
        }
    }
}

/// Close a window and free all resources associated with it. This can
/// only be called from the main thread.
// pub fn closeWindow(self: *App, window: *Window) void {
//     var i: usize = 0;
//     while (i < self.surfaces.items.len) {
//         const current = self.surfaces.items[i];
//         if (window == current) {
//             window.destroy();
//             _ = self.surfaces.swapRemove(i);
//             return;
//         }
//
//         i += 1;
//     }
// }

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.runtime.App) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .new_tab => |msg| try self.newTab(rt_app, msg),
            .quit => try self.setQuit(),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
        }
    }
}

/// Create a new window
fn newWindow(self: *App, rt_app: *apprt.runtime.App, msg: Message.NewWindow) !void {
    const window = try rt_app.newWindow();
    if (self.config.@"window-inherit-font-size") {
        if (msg.parent) |parent| {
            if (self.hasSurface(parent)) {
                window.core_surface.setFontSize(parent.font_size);
            }
        }
    }
}

/// Create a new tab in the parent window
fn newTab(self: *App, rt_app: *apprt.runtime.App, msg: Message.NewTab) !void {
    const parent = msg.parent orelse {
        log.warn("parent must be set in new_tab message", .{});
        return;
    };

    // If the parent was closed prior to us handling the message, we do nothing.
    if (!self.hasSurface(parent)) {
        log.warn("new_tab parent is gone, not launching a new tab", .{});
        return;
    }

    const window = try rt_app.newTab(parent);
    if (self.config.@"window-inherit-font-size") window.core_surface.setFontSize(parent.font_size);
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

    /// Create a new tab within the tab group of the focused window.
    /// This does nothing if we're on a platform or using a window
    /// environment that doesn't support tabs.
    new_tab: NewTab,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    const NewWindow = struct {
        /// Runtime-specific window options.
        runtime: apprt.runtime.Surface.Options = .{},

        /// The parent surface
        parent: ?*Surface = null,
    };

    const NewTab = struct {
        /// The parent surface
        parent: ?*Surface = null,
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

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.tick() catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.runtime.opts.userdata;
    }

    export fn ghostty_app_free(ptr: ?*App) void {
        if (ptr) |v| {
            v.destroy();
            v.alloc.destroy(v);
        }
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.runtime.Window.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.runtime.Window.Options,
    ) !*Surface {
        const w = try app.newWindow(.{
            .runtime = opts.*,
        });
        return w;
    }

    export fn ghostty_surface_free(ptr: ?*Surface) void {
        if (ptr) |v| v.app.closeWindow(v);
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(win: *Surface) *App {
        return win.app;
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(win: *Surface) void {
        win.window.refresh();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(win: *Surface, w: u32, h: u32) void {
        win.window.updateSize(w, h);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(win: *Surface, x: f64, y: f64) void {
        win.window.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(win: *Surface, focused: bool) void {
        win.window.focusCallback(focused);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_key(
        win: *Surface,
        action: input.Action,
        key: input.Key,
        mods: c_int,
    ) void {
        win.window.keyCallback(
            action,
            key,
            @bitCast(input.Mods, @truncate(u8, @bitCast(c_uint, mods))),
        );
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_char(win: *Surface, codepoint: u32) void {
        win.window.charCallback(codepoint);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        win: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        win.window.mouseButtonCallback(
            action,
            button,
            @bitCast(input.Mods, @truncate(u8, @bitCast(c_uint, mods))),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(win: *Surface, x: f64, y: f64) void {
        win.window.cursorPosCallback(x, y);
    }

    export fn ghostty_surface_mouse_scroll(win: *Surface, x: f64, y: f64) void {
        win.window.scrollCallback(x, y);
    }

    export fn ghostty_surface_ime_point(win: *Surface, x: *f64, y: *f64) void {
        const pos = win.imePoint();
        x.* = pos.x;
        y.* = pos.y;
    }
};
