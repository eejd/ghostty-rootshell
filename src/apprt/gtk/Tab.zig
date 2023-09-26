const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub fn create(alloc: Allocator, window: *Window) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    try tab.init(window);
}

pub fn init(self: *Tab, window: *Window) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .close_button = undefined,
        .box = undefined,
        .child = undefined,
        .focus_child = undefined,
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
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const box: *c.GtkBox = @ptrCast(box_widget);
    self.box = box;
    // todo - write the rest of function and initialize a new Surface
}
