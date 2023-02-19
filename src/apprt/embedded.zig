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
const CoreWindow = @import("../Window.zig");

const log = std.log.scoped(.embedded_window);

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// Userdata that is passed to all the callbacks.
        userdata: ?*anyopaque = null,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (?*anyopaque) callconv(.C) void,

        /// Called to set the title of the window.
        set_title: *const fn (?*anyopaque, [*]const u8) callconv(.C) void,
    };

    opts: Options,

    pub fn init(opts: Options) !App {
        return .{ .opts = opts };
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

pub const Window = struct {
    nsview: objc.Object,
    core_win: *CoreWindow,
    content_scale: apprt.ContentScale,
    size: apprt.WindowSize,
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

    pub fn init(app: *const CoreApp, core_win: *CoreWindow, opts: Options) !Window {
        _ = app;

        return .{
            .core_win = core_win,
            .nsview = objc.Object.fromId(opts.nsview),
            .content_scale = .{
                .x = @floatCast(f32, opts.scale_factor),
                .y = @floatCast(f32, opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = 0, .y = 0 },
            .opts = opts,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn getContentScale(self: *const Window) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Window) !apprt.WindowSize {
        return self.size;
    }

    pub fn setSizeLimits(self: *Window, min: apprt.WindowSize, max_: ?apprt.WindowSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Window, slice: [:0]const u8) !void {
        self.core_win.app.runtime.opts.set_title(
            self.opts.userdata,
            slice.ptr,
        );
    }

    pub fn getClipboardString(self: *const Window) ![:0]const u8 {
        _ = self;
        return "";
    }

    pub fn setClipboardString(self: *const Window, val: [:0]const u8) !void {
        _ = self;
        _ = val;
    }

    pub fn setShouldClose(self: *Window) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Window) bool {
        _ = self;
        return false;
    }

    pub fn getCursorPos(self: *const Window) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Window) void {
        self.core_win.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Window, x: f64, y: f64) void {
        self.content_scale = .{
            .x = @floatCast(f32, x),
            .y = @floatCast(f32, y),
        };
    }

    pub fn updateSize(self: *Window, width: u32, height: u32) void {
        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_win.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *const Window,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        self.core_win.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(self: *Window, x: f64, y: f64) void {
        // Convert our unscaled x/y to scaled.
        self.cursor_pos = self.core_win.window.cursorPosToPixels(.{
            .x = @floatCast(f32, x),
            .y = @floatCast(f32, y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        self.core_win.cursorPosCallback(self.cursor_pos) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn keyCallback(
        self: *const Window,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) void {
        // log.warn("key action={} key={} mods={}", .{ action, key, mods });
        self.core_win.keyCallback(action, key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn charCallback(self: *const Window, cp_: u32) void {
        const cp = std.math.cast(u21, cp_) orelse return;
        self.core_win.charCallback(cp) catch |err| {
            log.err("error in char callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *const Window, focused: bool) void {
        self.core_win.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Window, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};
