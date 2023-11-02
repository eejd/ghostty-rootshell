/// The state associated with a single tab in the window.
///
/// A tab can contain one or more terminals due to splits.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Paned = @import("Paned.zig");
const Parent = @import("relation.zig").Parent;
const Child = @import("relation.zig").Child;
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

pub const GHOSTTY_TAB = "ghostty_tab";

window: *Window,

/// The tab label.
label_text: *c.GtkLabel,

/// We'll put our children into this box instead of packing them
/// directly, so that we can send the box into `c.g_signal_connect_data`
/// for the close button
box: *c.GtkBox,

/// The element of this tab so that we can handle splits and so on.
elem: Surface.Container.Elem,

// The child can be either a Surface if the tab is not split or a Paned
child: Child,

// We'll update this every time a Surface gains focus, so that we have it
// when we switch to another Tab. Then when we switch back to this tab, we
// can easily re-focus that terminal.
focus_child: *Surface,

pub fn create(alloc: Allocator, window: *Window, parent_: ?*CoreSurface) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    try tab.init(window, parent_);
    return tab;
}

/// Initialize the tab, create a surface, and add it to the window. "self"
/// needs to be a stable pointer, since it is used for GTK events.
pub fn init(self: *Tab, window: *Window, parent_: ?*CoreSurface) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .box = undefined,
        .elem = undefined,
        .child = undefined,
        .focus_child = undefined,
    };

    // Build the tab label
    const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
    const label_text_widget = c.gtk_label_new("Ghostty");
    const label_text: *c.GtkLabel = @ptrCast(label_text_widget);
    c.gtk_box_append(label_box, label_text_widget);
    self.label_text = label_text;

    // Build the close button for the tab
    const label_close_widget = c.gtk_button_new_from_icon_name("window-close");
    const label_close: *c.GtkButton = @ptrCast(label_close_widget);
    c.gtk_button_set_has_frame(label_close, 0);
    c.gtk_box_append(label_box, label_close_widget);

    // Wide style GTK tabs
    if (window.app.config.@"gtk-wide-tabs") {
        c.gtk_widget_set_hexpand(label_box_widget, 1);
        c.gtk_widget_set_halign(label_box_widget, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_hexpand(label_text_widget, 1);
        c.gtk_widget_set_halign(label_text_widget, c.GTK_ALIGN_FILL);

        // This ensures that tabs are always equal width. If they're too
        // long, they'll be truncated with an ellipsis.
        c.gtk_label_set_max_width_chars(@ptrCast(label_text), 1);
        c.gtk_label_set_ellipsize(@ptrCast(label_text), c.PANGO_ELLIPSIZE_END);

        // We need to set a minimum width so that at a certain point
        // the notebook will have an arrow button rather than shrinking tabs
        // to an unreadably small size.
        c.gtk_widget_set_size_request(@ptrCast(label_text), 100, 1);
    }

    // Create a Box in which we'll later keep either Surface or Paned
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(box_widget, 1);
    c.gtk_widget_set_vexpand(box_widget, 1);
    self.box = @ptrCast(box_widget);

    // Create the initial surface since all tabs start as a single non-split
    var surface = try Surface.create(window.app.core_app.alloc, window.app, .{
        .parent2 = parent_,
    });
    errdefer surface.destroy(window.app.core_app.alloc);
    surface.setContainer(.{ .tab_ = self });
    self.child = .{ .surface = surface };
    self.elem = .{ .surface = surface };

    // Add Surface to the Tab
    const gl_area_widget = @as(*c.GtkWidget, @ptrCast(surface.gl_area));
    c.gtk_box_append(self.box, gl_area_widget);

    // Add the notebook page (create tab). We create the tab after our
    // current selected tab if we have one.
    const page_idx = c.gtk_notebook_insert_page(
        window.notebook,
        box_widget,
        label_box_widget,
        c.gtk_notebook_get_current_page(window.notebook) + 1,
    );
    if (page_idx < 0) {
        log.warn("failed to add page to notebook", .{});
        return error.GtkAppendPageFailed;
    }

    // Tab settings
    c.gtk_notebook_set_tab_reorderable(window.notebook, box_widget, 1);
    c.gtk_notebook_set_tab_detachable(window.notebook, box_widget, 1);

    // If we have multiple tabs, show the tab bar.
    if (c.gtk_notebook_get_n_pages(window.notebook) > 1) {
        c.gtk_notebook_set_show_tabs(window.notebook, 1);
    }

    // Set the userdata of the box to point to this tab.
    c.g_object_set_data(@ptrCast(box_widget), GHOSTTY_TAB, self);

    // Attach all events
    _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&gtkTabCloseClick), self, null, c.G_CONNECT_DEFAULT);

    // Switch to the new tab
    c.gtk_notebook_set_current_page(window.notebook, page_idx);

    // We need to grab focus after Surface and Tab is added to the window. When
    // creating a Tab we want to always focus on the widget.
    surface.grabFocus();
}

/// Deinits tab by deiniting child if child is Paned.
pub fn deinit(self: *Tab) void {
    switch (self.child) {
        .none, .surface => return,
        .paned => |paned| {
            paned.deinit(self.window.app.core_app.alloc);
            self.window.app.core_app.alloc.destroy(paned);
        },
    }
}

/// Remove the current child from the Tab. Noop if no child set.
pub fn removeChild(self: *Tab) void {
    const widget = self.child.widget() orelse return;
    c.gtk_box_remove(self.box, widget);

    self.child = .none;
}

// TODO: move this
/// Replace the surface element that this tab is showing.
pub fn replaceElem(self: *Tab, elem: Surface.Container.Elem) void {
    // Remove our previous widget
    c.gtk_box_remove(self.box, self.elem.widget());

    // Add our new one
    c.gtk_box_append(self.box, elem.widget());
    self.elem = elem;
}

// TODO: move this
/// The surface element is closing. If we're the direct parent
/// then that means our tab is also closing.
pub fn closeElem(self: *Tab) void {
    self.window.closeTab(self);
}

/// Sets child to given child and sets parent on child.
pub fn setChild(self: *Tab, child: Child) void {
    const widget = child.widget() orelse return;
    c.gtk_box_append(self.box, widget);

    child.setParent(.{ .tab = self });
    self.child = child;
}

fn gtkTabCloseClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    const tab: *Tab = @ptrCast(@alignCast(ud));
    const window = tab.window;
    window.closeTab(tab);
}
