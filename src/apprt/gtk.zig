//! Application runtime that uses GTK4.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const apprt = @import("../apprt.zig");
const input = @import("../input.zig");
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

    cursor_default: *c.GdkCursor,
    cursor_ibeam: *c.GdkCursor,

    pub fn init(core_app: *CoreApp, opts: Options) !App {
        // This is super weird, but we still use GLFW with GTK only so that
        // we can tap into their folklore logic to get screen DPI. If we can
        // figure out a reliable way to determine this ourselves, we can get
        // rid of this dep.
        if (!glfw.init(.{})) return error.GlfwInitFailed;

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

        // Get our cursors
        const cursor_default = c.gdk_cursor_new_from_name("default", null).?;
        errdefer c.g_object_unref(cursor_default);
        const cursor_ibeam = c.gdk_cursor_new_from_name("text", cursor_default).?;
        errdefer c.g_object_unref(cursor_ibeam);

        return .{
            .core_app = core_app,
            .app = app,
            .ctx = ctx,
            .cursor_default = cursor_default,
            .cursor_ibeam = cursor_ibeam,
        };
    }

    // Terminate the application. The application will not be restarted after
    // this so all global state can be cleaned up.
    pub fn terminate(self: App) void {
        c.g_settings_sync();
        while (c.g_main_context_iteration(self.ctx, 0) != 0) {}
        c.g_main_context_release(self.ctx);
        c.g_object_unref(self.app);

        c.g_object_unref(self.cursor_ibeam);
        c.g_object_unref(self.cursor_default);

        glfw.terminate();
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

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        surface.invalidate();
    }

    pub fn newWindow(self: *App, parent_: ?*CoreSurface) !void {
        _ = parent_;

        // Grab a surface allocation we'll need it later.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the window
        const window = c.gtk_application_window_new(self.app);
        const gtk_window = @ptrCast(*c.GtkWindow, window);
        errdefer c.gtk_window_destroy(gtk_window);
        c.gtk_window_set_title(gtk_window, "Ghostty");
        c.gtk_window_set_default_size(gtk_window, 200, 200);
        c.gtk_widget_show(window);

        // Create a notebook to hold our tabs.
        const notebook_widget = c.gtk_notebook_new();
        const notebook = @ptrCast(*c.GtkNotebook, notebook_widget);
        c.gtk_notebook_set_tab_pos(notebook, c.GTK_POS_TOP);

        // Initialize the GtkGLArea and attach it to our surface.
        // The surface starts in the "unrealized" state because we have to
        // wait for the "realize" callback from GTK to know that the OpenGL
        // context is ready. See Surface docs for more info.
        const gl_area = c.gtk_gl_area_new();
        const label = c.gtk_label_new("Ghostty");
        try surface.init(self, .{
            .gl_area = @ptrCast(*c.GtkGLArea, gl_area),
            .title_label = @ptrCast(*c.GtkLabel, label),
        });
        errdefer surface.deinit();
        if (c.gtk_notebook_append_page(notebook, gl_area, label) < 0) {
            log.warn("failed to add surface to notebook", .{});
            return error.GtkAppendPageFailed;
        }

        // The notebook is our main child
        c.gtk_window_set_child(gtk_window, notebook_widget);

        // We need to grab focus after it is added to the window. When
        // creating a window we want to always focus on the widget.
        const widget = @ptrCast(*c.GtkWidget, gl_area);
        _ = c.gtk_widget_grab_focus(widget);
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
    /// This is detected by the OpenGL renderer to move to a single-threaded
    /// draw operation. This basically puts locks around our draw path.
    pub const opengl_single_threaded_draw = true;

    pub const Options = struct {
        gl_area: *c.GtkGLArea,

        /// The label to use as the title of this surface. This will be
        /// modified with setTitle.
        title_label: ?*c.GtkLabel = null,
    };

    /// Where the title of this surface will go.
    const Title = union(enum) {
        none: void,
        label: *c.GtkLabel,
    };

    /// Whether the surface has been realized or not yet. When a surface is
    /// "realized" it means that the OpenGL context is ready and the core
    /// surface has been initialized.
    realized: bool = false,

    /// The app we're part of
    app: *App,

    /// Our GTK area
    gl_area: *c.GtkGLArea,

    /// Our title label (if there is one).
    title: Title,

    /// The core surface backing this surface
    core_surface: CoreSurface,

    /// Cached metrics about the surface from GTK callbacks.
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    clipboard: c.GValue,

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        const widget = @ptrCast(*c.GtkWidget, opts.gl_area);
        c.gtk_gl_area_set_required_version(opts.gl_area, 3, 3);
        c.gtk_gl_area_set_has_stencil_buffer(opts.gl_area, 0);
        c.gtk_gl_area_set_has_depth_buffer(opts.gl_area, 0);
        c.gtk_gl_area_set_use_es(opts.gl_area, 0);

        // Key event controller will tell us about raw keypress events.
        const ec_key = c.gtk_event_controller_key_new();
        errdefer c.g_object_unref(ec_key);
        c.gtk_widget_add_controller(widget, ec_key);
        errdefer c.gtk_widget_remove_controller(widget, ec_key);

        // Focus controller will tell us about focus enter/exit events
        const ec_focus = c.gtk_event_controller_focus_new();
        errdefer c.g_object_unref(ec_focus);
        c.gtk_widget_add_controller(widget, ec_focus);
        errdefer c.gtk_widget_remove_controller(widget, ec_focus);

        // Tell the key controller that we're interested in getting a full
        // input method so raw characters/strings are given too.
        const im_context = c.gtk_im_multicontext_new();
        errdefer c.g_object_unref(im_context);
        c.gtk_event_controller_key_set_im_context(
            @ptrCast(*c.GtkEventControllerKey, ec_key),
            im_context,
        );

        // Create a second key controller so we can receive the raw
        // key-press events BEFORE the input method gets them.
        const ec_key_press = c.gtk_event_controller_key_new();
        errdefer c.g_object_unref(ec_key_press);
        c.gtk_widget_add_controller(widget, ec_key_press);
        errdefer c.gtk_widget_remove_controller(widget, ec_key_press);

        // Clicks
        const gesture_click = c.gtk_gesture_click_new();
        errdefer c.g_object_unref(gesture_click);
        c.gtk_gesture_single_set_button(@ptrCast(
            *c.GtkGestureSingle,
            gesture_click,
        ), 0);
        c.gtk_widget_add_controller(widget, @ptrCast(
            *c.GtkEventController,
            gesture_click,
        ));

        // Mouse movement
        const ec_motion = c.gtk_event_controller_motion_new();
        errdefer c.g_object_unref(ec_motion);
        c.gtk_widget_add_controller(widget, ec_motion);

        // Scroll events
        const ec_scroll = c.gtk_event_controller_scroll_new(
            c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
                c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
        );
        errdefer c.g_object_unref(ec_scroll);
        c.gtk_widget_add_controller(widget, ec_scroll);

        // The GL area has to be focusable so that it can receive events
        c.gtk_widget_set_focusable(widget, 1);
        c.gtk_widget_set_focus_on_click(widget, 1);

        // When we're over the widget, set the cursor to the ibeam
        c.gtk_widget_set_cursor(widget, app.cursor_ibeam);

        // Build our result
        self.* = .{
            .app = app,
            .gl_area = opts.gl_area,
            .title = if (opts.title_label) |label| .{
                .label = label,
            } else .{ .none = {} },
            .core_surface = undefined,
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = 0, .y = 0 },
            .clipboard = std.mem.zeroes(c.GValue),
        };
        errdefer self.* = undefined;

        // GL events
        _ = c.g_signal_connect_data(opts.gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, c.G_CONNECT_DEFAULT);

        _ = c.g_signal_connect_data(ec_key_press, "key-pressed", c.G_CALLBACK(&gtkKeyPressed), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_key_press, "key-released", c.G_CALLBACK(&gtkKeyReleased), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_focus, "enter", c.G_CALLBACK(&gtkFocusEnter), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_focus, "leave", c.G_CALLBACK(&gtkFocusLeave), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im_context, "commit", c.G_CALLBACK(&gtkInputCommit), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_click, "pressed", c.G_CALLBACK(&gtkMouseDown), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_click, "released", c.G_CALLBACK(&gtkMouseUp), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_motion, "motion", c.G_CALLBACK(&gtkMouseMotion), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_scroll, "scroll", c.G_CALLBACK(&gtkMouseScroll), self, null, c.G_CONNECT_DEFAULT);
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

        // Note we're realized
        self.realized = true;
    }

    pub fn deinit(self: *Surface) void {
        c.g_value_unset(&self.clipboard);

        // We don't allocate anything if we aren't realized.
        if (!self.realized) return;

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
        self.core_surface = undefined;
    }

    fn render(self: *Surface) !void {
        try self.core_surface.renderer.draw();
    }

    /// Invalidate the surface so that it forces a redraw on the next tick.
    fn invalidate(self: *Surface) void {
        c.gtk_gl_area_queue_render(self.gl_area);
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
        const monitor = glfw.Monitor.getPrimary() orelse return error.NoMonitor;
        const scale = monitor.getContentScale();
        return apprt.ContentScale{ .x = scale.x_scale, .y = scale.y_scale };
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
        switch (self.title) {
            .none => {},

            .label => |label| {
                c.gtk_label_set_text(label, slice.ptr);
            },
        }

        // const root = c.gtk_widget_get_root(@ptrCast(
        //     *c.GtkWidget,
        //     self.gl_area,
        // ));
    }

    pub fn getClipboardString(self: *Surface) ![:0]const u8 {
        const clipboard = c.gtk_widget_get_clipboard(@ptrCast(
            *c.GtkWidget,
            self.gl_area,
        ));

        const content = c.gdk_clipboard_get_content(clipboard) orelse {
            // On my machine, this NEVER works, so we fallback to glfw's
            // implementation...
            log.debug("no GTK clipboard contents, falling back to glfw", .{});
            return glfw.getClipboardString() orelse return glfw.mustGetErrorCode();
        };

        c.g_value_unset(&self.clipboard);
        _ = c.g_value_init(&self.clipboard, c.G_TYPE_STRING);
        if (c.gdk_content_provider_get_value(content, &self.clipboard, null) == 0) {
            return "";
        }

        const ptr = c.g_value_get_string(&self.clipboard);
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn setClipboardString(self: *const Surface, val: [:0]const u8) !void {
        const clipboard = c.gtk_widget_get_clipboard(@ptrCast(
            *c.GtkWidget,
            self.gl_area,
        ));

        c.gdk_clipboard_set_text(clipboard, val.ptr);
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
        log.debug("gl surface realized", .{});

        // We need to make the context current so we can call GL functions.
        c.gtk_gl_area_make_current(area);
        if (c.gtk_gl_area_get_error(area)) |err| {
            log.err("surface failed to realize: {s}", .{err.*.message});
            return;
        }

        // realize means that our OpenGL context is ready, so we can now
        // initialize the core surface which will setup the renderer.
        const self = userdataSelf(ud.?);
        self.realize() catch |err| {
            // TODO: we need to destroy the GL area here.
            log.err("surface failed to realize: {}", .{err});
            return;
        };
    }

    /// render singal
    fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
        _ = area;
        _ = ctx;

        const self = userdataSelf(ud.?);
        self.render() catch |err| {
            log.err("surface failed to render: {}", .{err});
            return 0;
        };

        return 1;
    }

    /// render singal
    fn gtkResize(area: *c.GtkGLArea, width: c.gint, height: c.gint, ud: ?*anyopaque) callconv(.C) void {
        _ = area;
        log.debug("gl resize {} {}", .{ width, height });

        const self = userdataSelf(ud.?);
        self.size = .{
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
        };

        // Call the primary callback.
        if (self.realized) {
            self.core_surface.sizeCallback(self.size) catch |err| {
                log.err("error in size callback err={}", .{err});
                return;
            };
        }
    }

    /// "destroy" signal for surface
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;
        log.debug("gl destroy", .{});

        const self = userdataSelf(ud.?);
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    fn gtkMouseDown(
        gesture: *c.GtkGestureClick,
        _: c.gint,
        _: c.gdouble,
        _: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(
            *c.GtkGestureSingle,
            gesture,
        )));

        // If we don't have focus, grab it.
        const gl_widget = @ptrCast(*c.GtkWidget, self.gl_area);
        if (c.gtk_widget_has_focus(gl_widget) == 0) {
            _ = c.gtk_widget_grab_focus(gl_widget);
        }

        self.core_surface.mouseButtonCallback(.press, button, .{}) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseUp(
        gesture: *c.GtkGestureClick,
        _: c.gint,
        _: c.gdouble,
        _: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(
            *c.GtkGestureSingle,
            gesture,
        )));

        const self = userdataSelf(ud.?);
        self.core_surface.mouseButtonCallback(.release, button, .{}) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseMotion(
        _: *c.GtkEventControllerMotion,
        x: c.gdouble,
        y: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.cursor_pos = .{
            .x = @max(0, @floatCast(f32, x)),
            .y = @floatCast(f32, y),
        };

        self.core_surface.cursorPosCallback(self.cursor_pos) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseScroll(
        _: *c.GtkEventControllerScroll,
        x: c.gdouble,
        y: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.core_surface.scrollCallback(x, y * -1) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    fn gtkKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        ud: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        _ = keycode;

        const key = translateKey(keyval);
        const mods = translateMods(state);
        const self = userdataSelf(ud.?);
        log.debug("key-press key={} mods={}", .{ key, mods });
        self.core_surface.keyCallback(.press, key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return 0;
        };

        return 0;
    }

    fn gtkKeyReleased(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        ud: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        _ = keycode;

        const key = translateKey(keyval);
        const mods = translateMods(state);
        const self = userdataSelf(ud.?);
        self.core_surface.keyCallback(.release, key, mods) catch |err| {
            log.err("error in key callback err={}", .{err});
            return 0;
        };

        return 0;
    }

    fn gtkInputCommit(
        _: *c.GtkIMContext,
        bytes: [*:0]u8,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const str = std.mem.sliceTo(bytes, 0);
        const view = std.unicode.Utf8View.init(str) catch |err| {
            log.warn("cannot build utf8 view over input: {}", .{err});
            return;
        };

        const self = userdataSelf(ud.?);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            self.core_surface.charCallback(cp) catch |err| {
                log.err("error in char callback err={}", .{err});
                return;
            };
        }
    }

    fn gtkFocusEnter(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.core_surface.focusCallback(true) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn gtkFocusLeave(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.core_surface.focusCallback(false) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn userdataSelf(ud: *anyopaque) *Surface {
        return @ptrCast(*Surface, @alignCast(@alignOf(Surface), ud));
    }
};

fn translateMouseButton(button: c.guint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}

fn translateMods(state: c.GdkModifierType) input.Mods {
    var mods: input.Mods = .{};
    if (state & c.GDK_SHIFT_MASK != 0) mods.shift = true;
    if (state & c.GDK_CONTROL_MASK != 0) mods.ctrl = true;
    if (state & c.GDK_ALT_MASK != 0) mods.alt = true;
    if (state & c.GDK_SUPER_MASK != 0) mods.super = true;

    // Lock is dependent on the X settings but we just assume caps lock.
    if (state & c.GDK_LOCK_MASK != 0) mods.caps_lock = true;
    return mods;
}

fn translateKey(keyval: c.guint) input.Key {
    return switch (keyval) {
        c.GDK_KEY_a => .a,
        c.GDK_KEY_b => .b,
        c.GDK_KEY_c => .c,
        c.GDK_KEY_d => .d,
        c.GDK_KEY_e => .e,
        c.GDK_KEY_f => .f,
        c.GDK_KEY_g => .g,
        c.GDK_KEY_h => .h,
        c.GDK_KEY_i => .i,
        c.GDK_KEY_j => .j,
        c.GDK_KEY_k => .k,
        c.GDK_KEY_l => .l,
        c.GDK_KEY_m => .m,
        c.GDK_KEY_n => .n,
        c.GDK_KEY_o => .o,
        c.GDK_KEY_p => .p,
        c.GDK_KEY_q => .q,
        c.GDK_KEY_r => .r,
        c.GDK_KEY_s => .s,
        c.GDK_KEY_t => .t,
        c.GDK_KEY_u => .u,
        c.GDK_KEY_v => .v,
        c.GDK_KEY_w => .w,
        c.GDK_KEY_x => .x,
        c.GDK_KEY_y => .y,
        c.GDK_KEY_z => .z,

        c.GDK_KEY_0 => .zero,
        c.GDK_KEY_1 => .one,
        c.GDK_KEY_2 => .two,
        c.GDK_KEY_3 => .three,
        c.GDK_KEY_4 => .four,
        c.GDK_KEY_5 => .five,
        c.GDK_KEY_6 => .six,
        c.GDK_KEY_7 => .seven,
        c.GDK_KEY_8 => .eight,
        c.GDK_KEY_9 => .nine,

        c.GDK_KEY_semicolon => .semicolon,
        c.GDK_KEY_space => .space,
        c.GDK_KEY_apostrophe => .apostrophe,
        c.GDK_KEY_comma => .comma,
        c.GDK_KEY_grave => .grave_accent, // `
        c.GDK_KEY_period => .period,
        c.GDK_KEY_slash => .slash,
        c.GDK_KEY_minus => .minus,
        c.GDK_KEY_equal => .equal,
        c.GDK_KEY_bracketleft => .left_bracket, // [
        c.GDK_KEY_bracketright => .right_bracket, // ]
        c.GDK_KEY_backslash => .backslash, // /

        c.GDK_KEY_Up => .up,
        c.GDK_KEY_Down => .down,
        c.GDK_KEY_Right => .right,
        c.GDK_KEY_Left => .left,
        c.GDK_KEY_Home => .home,
        c.GDK_KEY_End => .end,
        c.GDK_KEY_Insert => .insert,
        c.GDK_KEY_Delete => .delete,
        c.GDK_KEY_Caps_Lock => .caps_lock,
        c.GDK_KEY_Scroll_Lock => .scroll_lock,
        c.GDK_KEY_Num_Lock => .num_lock,
        c.GDK_KEY_Page_Up => .page_up,
        c.GDK_KEY_Page_Down => .page_down,
        c.GDK_KEY_Escape => .escape,
        c.GDK_KEY_Return => .enter,
        c.GDK_KEY_Tab => .tab,
        c.GDK_KEY_BackSpace => .backspace,
        c.GDK_KEY_Print => .print_screen,
        c.GDK_KEY_Pause => .pause,

        c.GDK_KEY_F1 => .f1,
        c.GDK_KEY_F2 => .f2,
        c.GDK_KEY_F3 => .f3,
        c.GDK_KEY_F4 => .f4,
        c.GDK_KEY_F5 => .f5,
        c.GDK_KEY_F6 => .f6,
        c.GDK_KEY_F7 => .f7,
        c.GDK_KEY_F8 => .f8,
        c.GDK_KEY_F9 => .f9,
        c.GDK_KEY_F10 => .f10,
        c.GDK_KEY_F11 => .f11,
        c.GDK_KEY_F12 => .f12,
        c.GDK_KEY_F13 => .f13,
        c.GDK_KEY_F14 => .f14,
        c.GDK_KEY_F15 => .f15,
        c.GDK_KEY_F16 => .f16,
        c.GDK_KEY_F17 => .f17,
        c.GDK_KEY_F18 => .f18,
        c.GDK_KEY_F19 => .f19,
        c.GDK_KEY_F20 => .f20,
        c.GDK_KEY_F21 => .f21,
        c.GDK_KEY_F22 => .f22,
        c.GDK_KEY_F23 => .f23,
        c.GDK_KEY_F24 => .f24,
        c.GDK_KEY_F25 => .f25,

        c.GDK_KEY_KP_0 => .kp_0,
        c.GDK_KEY_KP_1 => .kp_1,
        c.GDK_KEY_KP_2 => .kp_2,
        c.GDK_KEY_KP_3 => .kp_3,
        c.GDK_KEY_KP_4 => .kp_4,
        c.GDK_KEY_KP_5 => .kp_5,
        c.GDK_KEY_KP_6 => .kp_6,
        c.GDK_KEY_KP_7 => .kp_7,
        c.GDK_KEY_KP_8 => .kp_8,
        c.GDK_KEY_KP_9 => .kp_9,
        c.GDK_KEY_KP_Decimal => .kp_decimal,
        c.GDK_KEY_KP_Divide => .kp_divide,
        c.GDK_KEY_KP_Multiply => .kp_multiply,
        c.GDK_KEY_KP_Subtract => .kp_subtract,
        c.GDK_KEY_KP_Add => .kp_add,
        c.GDK_KEY_KP_Enter => .kp_enter,
        c.GDK_KEY_KP_Equal => .kp_equal,

        c.GDK_KEY_Shift_L => .left_shift,
        c.GDK_KEY_Control_L => .left_control,
        c.GDK_KEY_Alt_L => .left_alt,
        c.GDK_KEY_Super_L => .left_super,
        c.GDK_KEY_Shift_R => .right_shift,
        c.GDK_KEY_Control_R => .right_control,
        c.GDK_KEY_Alt_R => .right_alt,
        c.GDK_KEY_Super_R => .right_super,

        else => .invalid,
    };
}
