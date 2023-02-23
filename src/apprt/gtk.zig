//! Application runtime that uses GTK4.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");

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

    core_app: *CoreApp,
    app: *c.GtkApplication,
    ctx: *c.GMainContext,

    pub fn init(core_app: *CoreApp, opts: Options) !App {
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

        return .{
            .core_app = core_app,
            .app = app,
            .ctx = ctx,
        };
    }

    // Terminate the application. The application will not be restarted after
    // this so all global state can be cleaned up.
    pub fn terminate(self: App) void {
        c.g_settings_sync();
        while (c.g_main_context_iteration(self.ctx, 0) != 0) {}
        c.g_main_context_release(self.ctx);
        c.g_object_unref(self.app);
    }

    pub fn wakeup(self: App) void {
        _ = self;
        c.g_main_context_wakeup(null);
    }

    /// Run the event loop. This doesn't return until the app exits.
    pub fn run(self: *App) !void {
        while (true) {
            _ = c.g_main_context_iteration(self.ctx, 1);

            // Tick the terminal app
            const should_quit = try self.core_app.tick(self);
            if (false and should_quit) return;
        }
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // This shouldn't be called because we should be working within
        // the GTK lifecycle and we can't just deallocate surfaces here.
        @panic("This should not be called with GTK.");
    }

    pub fn newWindow(self: *App, parent_: ?*CoreSurface) !void {
        _ = parent_;

        // Grab a surface allocation we'll need it later.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        const window = c.gtk_application_window_new(self.app);
        const gtk_window = @ptrCast(*c.GtkWindow, window);
        c.gtk_window_set_title(gtk_window, "Ghostty");
        c.gtk_window_set_default_size(gtk_window, 200, 200);
        c.gtk_widget_show(window);

        // Initialize the GtkGLArea and attach it to our surface.
        // The surface starts in the "unrealized" state because we have to
        // wait for the "realize" callback from GTK to know that the OpenGL
        // context is ready. See Surface docs for more info.
        const gl_area = c.gtk_gl_area_new();
        try surface.init(self, .{
            .gl_area = @ptrCast(*c.GtkGLArea, gl_area),
        });
        errdefer surface.deinit();
        c.gtk_window_set_child(gtk_window, gl_area);
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
};

pub const Surface = struct {
    pub const Options = struct {
        gl_area: *c.GtkGLArea,
    };

    /// Whether the surface has been realized or not yet. When a surface is
    /// "realized" it means that the OpenGL context is ready and the core
    /// surface has been initialized.
    realized: bool = false,

    /// The app we're part of
    app: *App,

    /// The core surface backing this surface
    core_surface: CoreSurface,

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        // Build our result
        self.* = .{
            .app = app,
            .core_surface = undefined,
        };
        errdefer self.* = undefined;

        // Create the GL area that will contain our surface
        _ = c.g_signal_connect_data(
            opts.gl_area,
            "realize",
            c.G_CALLBACK(&gtkRealize),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            opts.gl_area,
            "render",
            c.G_CALLBACK(&gtkRender),
            null,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            opts.gl_area,
            "destroy",
            c.G_CALLBACK(&gtkDestroy),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
    }

    fn realize(self: *Surface) !void {
        // Add ourselves to the list of surfaces on the app.
        try self.app.core_app.addSurface(self);
        errdefer self.app.core_app.deleteSurface(self);

        // Initialize our surface now that we have the stable pointer.
        try self.core_surface.init(
            self.app.core_app.alloc,
            self.app.core_app.config,
            .{ .rt_app = self.app, .mailbox = &self.app.core_app.mailbox },
            self,
        );
        errdefer self.core_surface.deinit();
    }

    fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
        _ = area;

        log.debug("gl surface realized", .{});

        // realize means that our OpenGL context is ready, so we can now
        // initialize the core surface which will setup the renderer.
        const self = userdataSelf(ud orelse return);
        self.realize() catch |err| {
            // TODO: we need to destroy the GL area here.
            log.err("surface failed to realize: {}", .{err});
            return;
        };
    }

    fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
        _ = area;
        _ = ctx;
        _ = ud;
        log.debug("gl render", .{});

        const opengl = @import("../renderer/opengl/main.zig");
        opengl.clearColor(0, 0.5, 1, 1);
        opengl.clear(opengl.c.GL_COLOR_BUFFER_BIT);

        return 1;
    }

    /// "destroy" signal for surface
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;

        const self = userdataSelf(ud orelse return);
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    fn userdataSelf(ud: *anyopaque) *Surface {
        return @ptrCast(*Surface, @alignCast(@alignOf(Surface), ud));
    }

    pub fn deinit(self: *Surface) void {
        _ = self;
    }

    pub fn setShouldClose(self: *Surface) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Surface) bool {
        _ = self;
        return false;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;
        return .{ .x = 1, .y = 1 };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        _ = self;
        return .{ .width = 800, .height = 600 };
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        _ = self;
        _ = slice;
    }

    pub fn getClipboardString(self: *const Surface) ![:0]const u8 {
        _ = self;
        return "";
    }

    pub fn setClipboardString(self: *const Surface, val: [:0]const u8) !void {
        _ = self;
        _ = val;
    }
};
