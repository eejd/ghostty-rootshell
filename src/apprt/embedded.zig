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
    };

    pub fn init(_: Options) !App {
        return .{};
    }

    pub fn terminate(self: App) void {
        _ = self;
    }

    pub fn wakeup(self: App) !void {
        _ = self;
    }

    pub fn wait(self: App) !void {
        _ = self;
    }
};

pub const Window = struct {
    nsview: objc.Object,
    scale_factor: f64,
    core_win: *CoreWindow,

    pub const Options = extern struct {
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
            .scale_factor = opts.scale_factor,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn getContentScale(self: *const Window) !apprt.ContentScale {
        _ = self;
        return apprt.ContentScale{ .x = 1, .y = 1 };
    }

    pub fn getSize(self: *const Window) !apprt.WindowSize {
        _ = self;

        // Initially our window will have a zero size. Until we can determine
        // the size of the window, we just send down this value.
        return apprt.WindowSize{ .width = 800, .height = 600 };
    }

    pub fn setSizeLimits(self: *Window, min: apprt.WindowSize, max_: ?apprt.WindowSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Window, slice: [:0]const u8) !void {
        _ = self;
        _ = slice;
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

    pub fn updateSize(self: *const Window, width: u32, height: u32) void {
        const size: apprt.WindowSize = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_win.sizeCallback(size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }
};
