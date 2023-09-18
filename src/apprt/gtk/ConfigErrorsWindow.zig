/// Configuration errors window.
const ConfigErrors = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;

const App = @import("App.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

app: *App,

layout: *c.GtkConstraintLayout,

pub fn create(app: *App) !void {
    if (app.config_errors_window != null) return error.InvalidOperation;

    const alloc = app.core_app.alloc;
    const self = try alloc.create(ConfigErrors);
    errdefer alloc.destroy(self);
    try self.init(app);

    app.config_errors_window = self;
}

/// Not public because this should be called by the GTK lifecycle.
fn destroy(self: *ConfigErrors) void {
    c.g_object_unref(self.layout);

    const alloc = self.app.core_app.alloc;
    self.app.config_errors_window = null;
    alloc.destroy(self);
}

fn init(self: *ConfigErrors, app: *App) !void {
    // Create the window
    const window = c.gtk_application_window_new(app.app);
    const gtk_window: *c.GtkWindow = @ptrCast(window);
    errdefer c.gtk_window_destroy(gtk_window);
    c.gtk_window_set_title(gtk_window, "Configuration Errors");
    c.gtk_window_set_default_size(gtk_window, 600, 300);

    // Box to store our widgets
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_vexpand(box, 1);
    c.gtk_widget_set_hexpand(box, 1);
    c.gtk_window_set_child(@ptrCast(window), box);

    // We use a constraint-based layout so the window is resizeable
    const layout = c.gtk_constraint_layout_new();
    errdefer c.g_object_unref(layout);
    c.gtk_widget_set_layout_manager(@ptrCast(box), layout);

    // Create all of our widgets
    const label = c.gtk_label_new(
        "One or more configuration errors were found while loading " ++
            "the configuration. Please review the errors below and reload " ++
            "your configuration or ignore the erroneous lines.",
    );
    c.gtk_label_set_wrap(@ptrCast(label), 1);

    const buf = try contentsBuffer(&app.config);
    defer c.g_object_unref(buf);
    const text = c.gtk_text_view_new_with_buffer(buf);
    errdefer c.g_object_unref(text);
    c.gtk_text_view_set_editable(@ptrCast(text), 0);
    c.gtk_text_view_set_cursor_visible(@ptrCast(text), 0);

    const ignore_button = c.gtk_button_new_with_label("Ignore");
    errdefer c.g_object_unref(ignore_button);

    const reload_button = c.gtk_button_new_with_label("Reload Configuration");
    errdefer c.g_object_unref(reload_button);

    // This hooks up all our widgets to the window so they can be laid out
    // using the constraint-based layout.
    c.gtk_widget_set_parent(label, box);
    c.gtk_widget_set_name(label, "label");
    c.gtk_widget_set_parent(text, box);
    c.gtk_widget_set_name(text, "text");
    c.gtk_widget_set_parent(ignore_button, box);
    c.gtk_widget_set_name(ignore_button, "ignorebutton");
    c.gtk_widget_set_parent(reload_button, box);
    c.gtk_widget_set_name(reload_button, "reloadbutton");

    var gerr: ?*c.GError = null;
    const list = c.gtk_constraint_layout_add_constraints_from_description(
        @ptrCast(layout),
        &vfl,
        vfl.len,
        8,
        8,
        &gerr,
        "label",
        label,
        "text",
        text,
        "ignorebutton",
        ignore_button,
        "reloadbutton",
        reload_button,
        @as(?*anyopaque, null),
    );
    if (gerr) |err| {
        defer c.g_error_free(err);
        log.warn("error building window message={s}", .{err.message});
        return error.OperationFailed;
    }
    c.g_list_free(list);

    // We can do additional settings once the layout is setup
    c.gtk_text_view_set_top_margin(@ptrCast(text), 8);
    c.gtk_text_view_set_bottom_margin(@ptrCast(text), 8);
    c.gtk_text_view_set_left_margin(@ptrCast(text), 8);
    c.gtk_text_view_set_right_margin(@ptrCast(text), 8);

    // Signals
    _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);

    // Show the window
    c.gtk_widget_show(window);

    // Set some state
    self.* = .{
        .app = app,
        .layout = @ptrCast(layout),
    };
}

fn gtkDestroy(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    self.destroy();
}

fn userdataSelf(ud: *anyopaque) *ConfigErrors {
    return @ptrCast(@alignCast(ud));
}

/// Returns the GtkTextBuffer for the config errors that we want to show.
fn contentsBuffer(config: *const Config) !*c.GtkTextBuffer {
    const buf = c.gtk_text_buffer_new(null);
    errdefer c.g_object_unref(buf);

    for (config._errors.list.items) |err| {
        c.gtk_text_buffer_insert_at_cursor(buf, err.message, @intCast(err.message.len));
        c.gtk_text_buffer_insert_at_cursor(buf, "\n", -1);
    }

    return buf;
}

const vfl = [_][*:0]const u8{
    "H:|-8-[label]-8-|",
    "H:|[text]|",
    "H:[ignorebutton]-8-[reloadbutton]-8-|",
    "V:|[label(<=100)][text(>=100)]-[ignorebutton]-|",
    "V:|[label(<=100)][text(>=100)]-[reloadbutton]-|",
    "V:[label][text]-[ignorebutton]",
    "V:[label][text]-[reloadbutton]",
};
