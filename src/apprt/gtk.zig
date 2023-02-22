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

/// App is the entrypoint for the application. This is called after all
/// of the runtime-agnostic initialization is complete and we're ready
/// to start.
///
/// There is only ever one App instance per process. This is because most
/// application frameworks also have this restriction so it simplifies
/// the assumptions.
pub const App = struct {
    pub const Options = struct {
        /// GTK app ID
        id: [:0]const u8 = "com.mitchellh.ghostty",
    };

    app: *c.GtkApplication,
    ctx: *c.GMainContext,

    pub fn init(core_app: *CoreApp, opts: Options) !App {
        _ = core_app;

        // Create our GTK Application which encapsulates our process.
        const app = @ptrCast(?*c.GtkApplication, c.gtk_application_new(
            opts.id.ptr,
            c.G_APPLICATION_DEFAULT_FLAGS,
        )) orelse return error.GtkInitFailed;
        errdefer c.g_object_unref(app);
        _ = c.g_signal_connect_data(
            app,
            "activate",
            c.G_CALLBACK(&activate),
            null,
            null,
            c.G_CONNECT_DEFAULT,
        );

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

        // This just calls the "activate" signal but its part of the normal
        // startup routine so we just call it:
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        c.g_application_activate(gapp);

        return .{ .app = app, .ctx = ctx };
    }

    // Terminate the application. The application will not be restarted after
    // this so all global state can be cleaned up.
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

    pub fn newWindow(self: App) !void {
        const window = c.gtk_application_window_new(self.app);
        c.gtk_window_set_title(@ptrCast(*c.GtkWindow, window), "Ghostty");
        c.gtk_window_set_default_size(@ptrCast(*c.GtkWindow, window), 200, 200);

        const surface = c.gtk_gl_area_new();
        c.gtk_window_set_child(@ptrCast(*c.GtkWindow, window), surface);
        _ = c.g_signal_connect_data(
            surface,
            "realize",
            c.G_CALLBACK(&onSurfaceRealize),
            null,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            surface,
            "render",
            c.G_CALLBACK(&onSurfaceRender),
            null,
            null,
            c.G_CONNECT_DEFAULT,
        );

        c.gtk_widget_show(window);
    }

    fn activate(app: *c.GtkApplication, ud: ?*anyopaque) callconv(.C) void {
        _ = app;
        _ = ud;

        // We purposely don't do anything on activation right now. We have
        // this callback because if we don't then GTK emits a warning to
        // stderr that we don't want. We emit a debug log just so that we know
        // we reached this point.
        log.debug("application activated", .{});
    }

    fn onSurfaceRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
        _ = area;
        _ = ud;
        log.debug("gl surface realized", .{});
    }

    fn onSurfaceRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) void {
        _ = area;
        _ = ctx;
        _ = ud;
        log.debug("gl render", .{});
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
