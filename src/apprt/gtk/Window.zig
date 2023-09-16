/// A Window is a single, real GTK window.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const configpkg = @import("../../config.zig");
const font = @import("../../font/main.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

const TAB_CLOSE_PAGE = "tab_close_page";
const TAB_CLOSE_SURFACE = "tab_close_surface";

app: *App,

/// Our window
window: *c.GtkWindow,

/// The notebook (tab grouping) for this window.
notebook: *c.GtkNotebook,

/// The resources directory for the icon (if any). We need to retain a
/// pointer to this because GTK can use it at any time.
icon_search_dir: ?[:0]const u8 = null,

pub fn init(self: *Window, app: *App) !void {
    // Set up our own state
    self.* = .{
        .app = app,
        .window = undefined,
        .notebook = undefined,
    };

    // Create the window
    const window = c.gtk_application_window_new(app.app);
    const gtk_window: *c.GtkWindow = @ptrCast(window);
    errdefer c.gtk_window_destroy(gtk_window);
    self.window = gtk_window;
    c.gtk_window_set_title(gtk_window, "Ghostty");
    c.gtk_window_set_default_size(gtk_window, 1000, 600);

    // If we don't have the icon then we'll try to add our resources dir
    // to the search path and see if we can find it there.
    const icon_name = "com.mitchellh.ghostty";
    const icon_theme = c.gtk_icon_theme_get_for_display(c.gtk_widget_get_display(window));
    if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) icon: {
        const base = self.app.core_app.resources_dir orelse {
            log.info("gtk app missing Ghostty icon and no resources dir detected", .{});
            log.info("gtk app will not have Ghostty icon", .{});
            break :icon;
        };

        // Note that this method for adding the icon search path is
        // a fallback mechanism. The recommended mechanism is the
        // Freedesktop Icon Theme Specification. We distribute a ".desktop"
        // file in zig-out/share that should be installed to the proper
        // place.
        const dir = try std.fmt.allocPrintZ(app.core_app.alloc, "{s}/icons", .{base});
        self.icon_search_dir = dir;
        c.gtk_icon_theme_add_search_path(icon_theme, dir.ptr);
        if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) {
            log.warn("Ghostty icon for gtk app not found", .{});
        }
    }
    c.gtk_window_set_icon_name(gtk_window, icon_name);

    // Apply background opacity if we have it
    if (app.config.@"background-opacity" < 1) {
        c.gtk_widget_set_opacity(@ptrCast(window), app.config.@"background-opacity");
    }

    // Hide window decoration if configured. This has to happen before
    // `gtk_widget_show`.
    if (!app.config.@"window-decoration") {
        c.gtk_window_set_decorated(gtk_window, 0);
    }

    // Create a notebook to hold our tabs.
    const notebook_widget = c.gtk_notebook_new();
    const notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
    self.notebook = notebook;
    c.gtk_notebook_set_tab_pos(notebook, c.GTK_POS_TOP);
    c.gtk_notebook_set_scrollable(notebook, 1);
    c.gtk_notebook_set_show_tabs(notebook, 0);
    c.gtk_notebook_set_show_border(notebook, 0);

    // This is important so the notebook expands to fit available space.
    // Otherwise, it will be zero/zero in the box below.
    c.gtk_widget_set_vexpand(notebook_widget, 1);
    c.gtk_widget_set_hexpand(notebook_widget, 1);

    // Create our add button for new tabs
    const notebook_add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
    c.gtk_notebook_set_action_widget(notebook, notebook_add_btn, c.GTK_PACK_END);

    // Create our box which will hold our widgets.
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    // In debug we show a warning. This is a really common issue where
    // people build from source in debug and performance is really bad.
    if (builtin.mode == .Debug) {
        const warning = c.gtk_label_new("⚠️ You're running a debug build of Ghostty! Performance will be degraded.");
        c.gtk_widget_set_margin_top(warning, 10);
        c.gtk_widget_set_margin_bottom(warning, 10);
        c.gtk_box_append(@ptrCast(box), warning);
    }
    c.gtk_box_append(@ptrCast(box), notebook_widget);

    // All of our events
    _ = c.g_signal_connect_data(window, "close-request", c.G_CALLBACK(&gtkCloseRequest), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook_add_btn, "clicked", c.G_CALLBACK(&gtkTabAddClick), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), self, null, c.G_CONNECT_DEFAULT);

    // The box is our main child
    c.gtk_window_set_child(gtk_window, box);

    // Show the window
    c.gtk_widget_show(window);
}

pub fn deinit(self: *Window) void {
    if (self.icon_search_dir) |ptr| self.app.core_app.alloc.free(ptr);
}

/// Add a new tab to this window.
pub fn newTab(self: *Window, parent_: ?*CoreSurface) !void {
    // Grab a surface allocation we'll need it later.
    var surface = try self.app.core_app.alloc.create(Surface);
    errdefer self.app.core_app.alloc.destroy(surface);

    // Inherit the parent's font size if we are configured to.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (!self.app.config.@"window-inherit-font-size") break :font_size null;
        const parent = parent_ orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // Build our tab label
    const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
    const label_text = c.gtk_label_new("Ghostty");
    c.gtk_box_append(label_box, label_text);

    const label_close_widget = c.gtk_button_new_from_icon_name("window-close");
    const label_close = @as(*c.GtkButton, @ptrCast(label_close_widget));
    c.gtk_button_set_has_frame(label_close, 0);
    c.gtk_box_append(label_box, label_close_widget);
    _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&gtkTabCloseClick), self, null, c.G_CONNECT_DEFAULT);

    // Initialize the GtkGLArea and attach it to our surface.
    // The surface starts in the "unrealized" state because we have to
    // wait for the "realize" callback from GTK to know that the OpenGL
    // context is ready. See Surface docs for more info.
    const gl_area = c.gtk_gl_area_new();
    try surface.init(self.app, .{
        .window = self,
        .gl_area = @ptrCast(gl_area),
        .title_label = @ptrCast(label_text),
        .font_size = font_size,
    });
    errdefer surface.deinit();
    const page_idx = c.gtk_notebook_append_page(self.notebook, gl_area, label_box_widget);
    if (page_idx < 0) {
        log.warn("failed to add surface to notebook", .{});
        return error.GtkAppendPageFailed;
    }

    // Tab settings
    c.gtk_notebook_set_tab_reorderable(self.notebook, gl_area, 1);

    // If we have multiple tabs, show the tab bar.
    if (c.gtk_notebook_get_n_pages(self.notebook) > 1) {
        c.gtk_notebook_set_show_tabs(self.notebook, 1);
    }

    // Set the userdata of the close button so it points to this page.
    const page = c.gtk_notebook_get_page(self.notebook, gl_area) orelse
        return error.GtkNotebookPageNotFound;
    c.g_object_set_data(@ptrCast(label_close), TAB_CLOSE_SURFACE, surface);
    c.g_object_set_data(@ptrCast(label_close), TAB_CLOSE_PAGE, page);
    c.g_object_set_data(@ptrCast(gl_area), TAB_CLOSE_PAGE, page);

    // Switch to the new tab
    c.gtk_notebook_set_current_page(self.notebook, page_idx);

    // We need to grab focus after it is added to the window. When
    // creating a window we want to always focus on the widget.
    const widget = @as(*c.GtkWidget, @ptrCast(gl_area));
    _ = c.gtk_widget_grab_focus(widget);
}

/// Close the tab for the given notebook page. This will automatically
/// handle closing the window if there are no more tabs.
fn closeTab(self: *Window, page: *c.GtkNotebookPage) void {
    // Remove the page
    const page_idx = getNotebookPageIndex(page);
    c.gtk_notebook_remove_page(self.notebook, page_idx);

    const remaining = c.gtk_notebook_get_n_pages(self.notebook);
    switch (remaining) {
        // If we have no more tabs we close the window
        0 => c.gtk_window_destroy(self.window),

        // If we have one more tab we hide the tab bar
        1 => c.gtk_notebook_set_show_tabs(self.notebook, 0),

        else => {},
    }

    // If we have remaining tabs, we need to make sure we grab focus.
    if (remaining > 0) self.focusCurrentTab();
}

/// Close the surface. This surface must be definitely part of this window.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    assert(surface.window == self);
    self.closeTab(getNotebookPage(@ptrCast(surface.gl_area)) orelse return);
}

/// Go to the previous tab for a surface.
pub fn gotoPreviousTab(self: *Window, surface: *Surface) void {
    const page = getNotebookPage(@ptrCast(surface.gl_area)) orelse return;
    const page_idx = getNotebookPageIndex(page);

    // The next index is the previous or we wrap around.
    const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
        const max = c.gtk_notebook_get_n_pages(self.notebook);
        break :next_idx max -| 1;
    };

    // Do nothing if we have one tab
    if (next_idx == page_idx) return;

    c.gtk_notebook_set_current_page(self.notebook, next_idx);
    self.focusCurrentTab();
}

/// Go to the next tab for a surface.
pub fn gotoNextTab(self: *Window, surface: *Surface) void {
    const page = getNotebookPage(@ptrCast(surface.gl_area)) orelse return;
    const page_idx = getNotebookPageIndex(page);
    const max = c.gtk_notebook_get_n_pages(self.notebook) -| 1;
    const next_idx = if (page_idx < max) page_idx + 1 else 0;
    if (next_idx == page_idx) return;

    c.gtk_notebook_set_current_page(self.notebook, next_idx);
    self.focusCurrentTab();
}

/// Go to the specific tab index.
pub fn gotoTab(self: *Window, n: usize) void {
    if (n == 0) return;
    const max = c.gtk_notebook_get_n_pages(self.notebook);
    const page_idx = std.math.cast(c_int, n - 1) orelse return;
    if (page_idx < max) {
        c.gtk_notebook_set_current_page(self.notebook, page_idx);
        self.focusCurrentTab();
    }
}

/// Toggle fullscreen for this window.
pub fn toggleFullscreen(self: *Window, _: configpkg.NonNativeFullscreen) void {
    const is_fullscreen = c.gtk_window_is_fullscreen(self.window);
    if (is_fullscreen == 0) {
        c.gtk_window_fullscreen(self.window);
    } else {
        c.gtk_window_unfullscreen(self.window);
    }
}

/// Grabs focus on the currently selected tab.
fn focusCurrentTab(self: *Window) void {
    const page_idx = c.gtk_notebook_get_current_page(self.notebook);
    const widget = c.gtk_notebook_get_nth_page(self.notebook, page_idx);
    _ = c.gtk_widget_grab_focus(widget);
}

fn gtkTabAddClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const parent = self.app.core_app.focusedSurface();
    self.newTab(parent) catch |err| {
        log.warn("error adding new tab: {}", .{err});
        return;
    };
}

fn gtkTabCloseClick(btn: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    _ = ud;
    const surface: *Surface = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(btn), TAB_CLOSE_SURFACE) orelse return,
    ));

    surface.core_surface.close();
}

fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(self.notebook, page)));
    const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
    const label_text = c.gtk_label_get_text(gtk_label);
    c.gtk_window_set_title(self.window, label_text);
}

fn gtkCloseRequest(v: *c.GtkWindow, ud: ?*anyopaque) callconv(.C) bool {
    _ = v;
    log.debug("window close request", .{});
    const self = userdataSelf(ud.?);

    // If none of our surfaces need confirmation, we can just exit.
    for (self.app.core_app.surfaces.items) |surface| {
        if (surface.window == self) {
            if (surface.core_surface.needsConfirmQuit()) break;
        }
    } else {
        c.gtk_window_destroy(self.window);
        return true;
    }

    // Setup our basic message
    const alert = c.gtk_message_dialog_new(
        self.window,
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_QUESTION,
        c.GTK_BUTTONS_YES_NO,
        "Close this window?",
    );
    c.gtk_message_dialog_format_secondary_text(
        @ptrCast(alert),
        "All terminal sessions in this window will be terminated.",
    );

    // We want the "yes" to appear destructive.
    const yes_widget = c.gtk_dialog_get_widget_for_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_YES,
    );
    c.gtk_widget_add_css_class(yes_widget, "destructive-action");

    // We want the "no" to be the default action
    c.gtk_dialog_set_default_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_NO,
    );

    _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, c.G_CONNECT_DEFAULT);

    c.gtk_widget_show(alert);
    return true;
}

fn gtkCloseConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    c.gtk_window_destroy(@ptrCast(alert));
    if (response == c.GTK_RESPONSE_YES) {
        const self = userdataSelf(ud.?);
        c.gtk_window_destroy(self.window);
    }
}

/// "destroy" signal for the window
fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("window destroy", .{});

    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

/// Get the GtkNotebookPage for the given object. You must be sure the
/// object has the notebook page property set.
fn getNotebookPage(obj: *c.GObject) ?*c.GtkNotebookPage {
    return @ptrCast(@alignCast(
        c.g_object_get_data(obj, TAB_CLOSE_PAGE) orelse return null,
    ));
}

fn getNotebookPageIndex(page: *c.GtkNotebookPage) c_int {
    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, c.G_TYPE_INT);
    c.g_object_get_property(
        @ptrCast(@alignCast(page)),
        "position",
        &value,
    );

    return c.g_value_get_int(&value);
}

fn userdataSelf(ud: *anyopaque) *Window {
    return @ptrCast(@alignCast(ud));
}
