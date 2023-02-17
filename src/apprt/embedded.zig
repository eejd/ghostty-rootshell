//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreWindow = @import("../Window.zig");

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
    pub const Options = extern struct {
        id: usize,
    };

    pub fn init(app: *const CoreApp, core_win: *CoreWindow, opts: Options) !Window {
        _ = app;
        _ = core_win;
        _ = opts;
        return .{};
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
        return apprt.WindowSize{ .width = 1, .height = 1 };
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
};
