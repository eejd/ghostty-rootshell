const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const TerminalWindow = @import("Window.zig");
const ImguiWidget = @import("ImguiWidget.zig");
const c = @import("c.zig");
const icon = @import("icon.zig");

const log = std.log.scoped(.inspector);

/// A window to hold a dedicated inspector instance.
pub const Window = struct {
    app: *App,
    window: *c.GtkWindow,
    icon: icon.Icon,
    imgui_widget: ImguiWidget,

    pub fn create(alloc: Allocator, app: *App) !*Window {
        var window = try alloc.create(Window);
        errdefer alloc.destroy(window);
        try window.init(app);
        return window;
    }

    pub fn init(self: *Window, app: *App) !void {
        // Initialize to undefined
        self.* = .{
            .app = app,
            .icon = undefined,
            .window = undefined,
            .imgui_widget = undefined,
        };

        // Create the window
        const window = c.gtk_application_window_new(app.app);
        const gtk_window: *c.GtkWindow = @ptrCast(window);
        errdefer c.gtk_window_destroy(gtk_window);
        self.window = gtk_window;
        c.gtk_window_set_title(gtk_window, "Ghostty");
        c.gtk_window_set_default_size(gtk_window, 1000, 600);
        self.icon = try icon.appIcon(self.app, window);
        c.gtk_window_set_icon_name(gtk_window, self.icon.name);

        // Initialize our imgui widget
        try self.imgui_widget.init();
        errdefer self.imgui_widget.deinit();

        // Signals
        _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);

        // Show the window
        c.gtk_window_set_child(gtk_window, @ptrCast(self.imgui_widget.gl_area));
        c.gtk_widget_show(window);
    }

    pub fn deinit(self: *Window) void {
        self.icon.deinit(self.app);
    }

    /// "destroy" signal for the window
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;
        log.debug("window destroy", .{});

        const self: *Window = @ptrCast(@alignCast(ud.?));
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }
};
