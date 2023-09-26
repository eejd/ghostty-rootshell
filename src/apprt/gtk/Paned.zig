const Paned = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../font/main.zig");
const CoreSurface = @import("../../Surface.zig");

const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const c = @import("c.zig");

const Child = union(enum) {
    surface: *Surface,
    paned: *Paned,
    empty: void,
};

const Parent = union(enum) {
    tab: *Tab,
    paned: *Paned,
}

// We'll need to keep a reference to the Window this belongs to for various reasons
window: *c.GtkWindow,

// We keep track of the tab label's text so that if a child widget of this pane
// gets focus (and is a Surface) we can reset the tab label appropriately
label_text: *c.GtkWidget,

// Our actual GtkPaned widget
paned: *c.GtkPaned,

// We have two children, each of which can be either a Surface, another pane,
// or empty. We're going to keep track of which each child is here.
child1: Child,
child2: Child,

// We also hold a reference to our parent widget, so that when we close we can either
// maximize the parent pane, or close the tab.
parent: Parent,

pub fn create(alloc: Allocator, window: *Window, label_text: *c.GtkWidget) !*Paned {
    var paned = try alloc.create(Paned);
    errdefer alloc.destroy(paned);
    try paned.init(window, label_text);
    return paned;
}

pub fn init(self: *Paned, window: *Window, label_text: *c.GtkWidget) !void {
    self.* = .{
        .window = window,
        .label_text = label_text,
        .paned = undefined,
        .child1 = Child{.empty},
        .child2 = Child{.empty},
        .parent = undefined,
    };

    const paned = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL);
    const gtk_paned: *c.GtkPaned = @ptrCast(paned);
    errdefer c.gtk_widget_destroy(paned);
    self.paned = gtk_paned;

    const surface = try self.newSurface(self.window.actionSurface());
    // We know that both panels are currently empty, so we maximize the 1st
    c.gtk_paned_set_position(self.paned, 100);
    const child_widget: *c.GtkWidget = @ptrCast(surface.gl_area);
    const child = Child{ .surface = surface };
    c.gtk_paned_pack1(self.paned, child_widget, 1, 1);
    self.child1 = child;
}

pub fn newSurface(self: *Paned, parent_: ?*CoreSurface) !*Surface {
    // Grab a surface allocation we'll need it later.
    var surface = try self.window.app.core_app.alloc.create(Surface);
    errdefer self.window.app.core_app.alloc.destroy(surface);

    // Inherit the parent's font size if we are configured to.
    const font_size: ?font.face.DesiredSize = font_size: {
        if (!self.window.app.config.@"window-inherit-font-size") break :font_size null;
        const parent = parent_ orelse break :font_size null;
        break :font_size parent.font_size;
    };

    // Initialize the GtkGLArea and attach it to our surface.
    // The surface starts in the "unrealized" state because we have to
    // wait for the "realize" callback from GTK to know that the OpenGL
    // context is ready. See Surface docs for more info.
    const gl_area = c.gtk_gl_area_new();
    try surface.init(self.window.app, .{
        .window = self,
        .gl_area = @ptrCast(gl_area),
        .title_label = @ptrCast(label_text),
        .font_size = font_size,
    });
    return surface;
}
