//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const input = @import("../input.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");

const log = std.log.scoped(.embedded_window);

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.C) void,

        /// Called to set the title of the window.
        set_title: *const fn (SurfaceUD, [*]const u8) callconv(.C) void,

        /// Read the clipboard value. The return value must be preserved
        /// by the host until the next call.
        read_clipboard: *const fn (SurfaceUD) callconv(.C) [*:0]const u8,

        /// Write the clipboard value.
        write_clipboard: *const fn (SurfaceUD, [*:0]const u8) callconv(.C) void,
    };

    core_app: *CoreApp,
    opts: Options,

    pub fn init(core_app: *CoreApp, opts: Options) !App {
        return .{ .core_app = core_app, .opts = opts };
    }

    pub fn terminate(self: App) void {
        _ = self;
    }

    pub fn wakeup(self: App) !void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: App) !void {
        _ = self;
    }
};

pub const Surface = struct {
    nsview: objc.Object,
    core_surface: *CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    opts: Options,

    pub const Options = extern struct {
        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The pointer to the backing NSView for the surface.
        nsview: *anyopaque = undefined,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .core_surface = undefined,
            .nsview = objc.Object.fromId(opts.nsview),
            .content_scale = .{
                .x = @floatCast(f32, opts.scale_factor),
                .y = @floatCast(f32, opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = 0, .y = 0 },
            .opts = opts,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(self);
        errdefer app.app.deleteSurface(self);

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(app.app, app.app.config, self);
        errdefer self.core_surface.deinit();
    }

    pub fn deinit(self: *Surface) void {
        // Remove ourselves from the list of known surfaces in the app.
        self.core_surface.app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        self.core_surface.app.runtime.opts.set_title(
            self.opts.userdata,
            slice.ptr,
        );
    }

    pub fn getClipboardString(self: *const Surface) ![:0]const u8 {
        const ptr = self.core_surface.app.runtime.opts.read_clipboard(self.opts.userdata);
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn setClipboardString(self: *const Surface, val: [:0]const u8) !void {
        self.core_surface.app.runtime.opts.write_clipboard(self.opts.userdata, val.ptr);
    }

    pub fn setShouldClose(self: *Surface) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Surface) bool {
        _ = self;
        return false;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        self.content_scale = .{
            .x = @floatCast(f32, x),
            .y = @floatCast(f32, y),
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *const Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(self: *const Surface, xoff: f64, yoff: f64) void {
        self.core_surface.scrollCallback(xoff, yoff) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(self: *Surface, x: f64, y: f64) void {
        // Convert our unscaled x/y to scaled.
        self.cursor_pos = self.core_surface.window.cursorPosToPixels(.{
            .x = @floatCast(f32, x),
            .y = @floatCast(f32, y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        self.core_surface.cursorPosCallback(self.cursor_pos) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn keyCallback(
        self: *const Surface,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) void {
        // log.warn("key action={} key={} mods={}", .{ action, key, mods });
        self.core_surface.keyCallback(action, key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn charCallback(self: *const Surface, cp_: u32) void {
        const cp = std.math.cast(u21, cp_) orelse return;
        self.core_surface.charCallback(cp) catch |err| {
            log.err("error in char callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *const Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};
