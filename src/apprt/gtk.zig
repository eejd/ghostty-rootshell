//! Application runtime that uses GTK4.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreWindow = @import("../Window.zig");

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const log = std.log.scoped(.gtk);

pub const App = struct {
    pub const Options = struct {
        /// GTK app ID
        id: [:0]const u8 = "com.mitchellh.ghostty",
    };

    app: *c.GtkApplication,
    ctx: *c.GMainContext,

    pub fn init(opts: Options) !App {
        const app = @ptrCast(?*c.GtkApplication, c.gtk_application_new(
            opts.id.ptr,
            c.G_APPLICATION_DEFAULT_FLAGS,
        )) orelse return error.GtkInitFailed;
        errdefer c.g_object_unref(app);

        // We don't use g_application_run, we want to manually control the
        // loop so we have to do the same things the run function does:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533
        const ctx = c.g_main_context_default() orelse return error.GtkContextFailed;
        if (c.g_main_context_acquire(ctx) == 0) return error.GtkContextAcquireFailed;
        errdefer c.g_main_context_release(ctx);

        const gapp = @ptrCast(*c.GApplication, app);
        var err_: ?*c.GError = null;
        if (c.g_application_register(
            gapp,
            null,
            @ptrCast([*c][*c]c.GError, &err_),
        ) == 0) {
            if (err_) |err| {
                log.warn("error registering application: {s}", .{err.message});
                c.g_error_free(err);
            }
            return error.GtkApplicationRegisterFailed;
        }

        c.g_application_activate(gapp);

        return .{ .app = app, .ctx = ctx };
    }

    pub fn terminate(self: App) void {
        c.g_settings_sync();
        while (c.g_main_context_iteration(self.ctx, 0) != 0) {}
        c.g_main_context_release(self.ctx);
        c.g_object_unref(self.app);
    }

    pub fn wakeup(self: App) !void {
        _ = self;
        c.g_main_context_wakeup(null);
    }

    pub fn wait(self: App) !void {
        _ = c.g_main_context_iteration(self.ctx, 1);
    }
};

pub const Window = struct {
    pub const Options = struct {};

    pub fn init(app: *const CoreApp, core_win: *CoreWindow, opts: Options) !Window {
        _ = app;
        _ = core_win;
        _ = opts;

        return .{};
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn setShouldClose(self: *Window) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Window) bool {
        _ = self;
        return false;
    }

    pub fn getContentScale(self: *const Window) !apprt.ContentScale {
        _ = self;
        return .{ .x = 1, .y = 1 };
    }

    pub fn getSize(self: *const Window) !apprt.WindowSize {
        _ = self;
        return .{ .width = 800, .height = 600 };
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
};
