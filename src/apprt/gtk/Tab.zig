const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../font/main.zig");
const CoreSurface = @import("../../Surface.zig");
const Paned = @import("Paned.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const Child = union(enum) {
    surface: *Surface,
    paned: *Paned,
};

window: *Window,
label_text: *c.GtkLabel,
close_button: *c.GtkButton,
// We'll put our children into this box instead of packing them directly, so
// that we can send the box into `c.g_signal_connect_data` for the close button
box: *c.GtkBox,
// The child can be either a Surface if the tab is not split or a Paned
child: Child,
// We'll update this every time a Surface gains focus, so that we have it
// when we switch to another Tab. Then when we switch back to this tab, we
// can easily re-focus that terminal.
focus_child: *Surface,

pub fn create(alloc: Allocator, window: *Window, parent_: ?*CoreSurface) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    try tab.init(window, _parent);
}

pub fn init(self: *Tab, window: *Window, parent_: ?*CoreSurface) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .close_button = undefined,
        .box = undefined,
        .child = undefined,
        .focus_child = undefined,
    };

    // Grab a surface allocation we'll need it later.
    var surface = try self.app.core_app.alloc.create(Surface);
    errdefer self.app.core_app.alloc.destroy(surface);

    // Inherit the parent's font size if we are configured to.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (!window.app.config.@"window-inherit-font-size") break :font_size null;
        const parent = parent_ orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // Build the tab label
    const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const label_box: *c.GtkBox = @ptrCast(label_box_widget);
    const label_text_widget = c.gtk_label_new("Ghostty");
    const label_text: *c.GtkLabel = @ptrCast(label_text_widget);
    self.label_text = label_text;
    c.gtk_box_append(label_box, label_text_widget);
    const label_close_widget = c.gtk_button_new_from_icon_name("window-close");
    const label_close: *c.GtkButton = @ptrCast(label_close_widget);
    c.gtk_button_has_frame(label_close, 0);
    c.gtk_box_append(label_box, label_close_widget);
    self.close_button = label_close;

    _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&gtkTabCloseClick), surface, null, c.G_CONNECT_DEFAULT);

    // Wide style GTK tabs
    if (self.app.config.@"gtk-wide-tabs") {
        c.gtk_widget_set_hexpand(label_box_widget, 1);
        c.gtk_widget_set_halign(label_box_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(label_text, 1);
        c.gtk_widget_set_halign(label_text, c.GTK_ALIGN_FILL);
    }

    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(box_widget, 1);
    c.gtk_widget_set_vexpand(box_widget, 1);
    self.box = ptrCast(box_widget);

    // Initialize the GtkGLArea and attach it to our surface.
    // The surface starts in the "unrealized" state because we have to
    // wait for the "realize" callback from GTK to know that the OpenGL
    // context is ready. See Surface docs for more info.
    const gl_area = c.gtk_gl_area_new();
    c.gtk_widget_set_hexpand(gl_area, 1);
    c.gtk_widget_set_vexpand(gl_area, 1);
    try surface.init(self.app, .{
        .window = self,
        .gl_area = @ptrCast(gl_area),
        .title_label = @ptrCast(label_text),
        .font_size = font_size,
    });
    errdefer surface.deinit();

    c.gtk_box_pack_start(self.box, gl_area);
    const page_idx = c.gtk_notebook_append_page(self.notebook, box_widget, label_box_widget);
    if (page_idx < 0) {
        log.warn("failed to add page to notebook", .{});
        return error.GtkAppendPageFailed;
    }

    // Tab settings
    c.gtk_notebook_set_tab_reorderable(self.notebook, gl_area, 1);
    c.gtk_notebook_set_tab_detachable(self.notebook, gl_area, 1);

    // If we have multiple tabs, show the tab bar.
    if (c.gtk_notebook_get_n_pages(self.notebook) > 1) {
        c.gtk_notebook_set_show_tabs(self.notebook, 1);
    }

    // Set the userdata of the close button so it points to this page.
    c.g_object_set_data(@ptrCast(box), GHOSTTY_TAB, self);

    // Switch to the new tab
    c.gtk_notebook_set_current_page(self.notebook, page_idx);

    // We need to grab focus after it is added to the window. When
    // creating a window we want to always focus on the widget.
    _ = c.gtk_widget_grab_focus(box_widget);
}
