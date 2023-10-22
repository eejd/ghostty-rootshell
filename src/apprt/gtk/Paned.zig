const Paned = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Position = @import("parent.zig").Position;
const Parent = @import("parent.zig").Parent;
const c = @import("c.zig");

/// We'll need to keep a reference to the Window this belongs to for various reasons
window: *Window,

// We keep track of the tab label's text so that if a child widget of this pane
// gets focus (and is a Surface) we can reset the tab label appropriately
label_text: *c.GtkWidget,

/// Our actual GtkPaned widget
paned: *c.GtkPaned,

// We have two children, each of which can be either a Surface, another pane,
// or empty. We're going to keep track of which each child is here.
child1: Tab.Child,
child2: Tab.Child,

// We also hold a reference to our parent widget, so that when we close we can either
// maximize the parent pane, or close the tab.
parent: Parent,

pub fn create(alloc: Allocator, window: *Window, direction: input.SplitDirection, label_text: *c.GtkWidget) !*Paned {
    var paned = try alloc.create(Paned);
    errdefer alloc.destroy(paned);
    try paned.init(window, direction, label_text);
    return paned;
}

pub fn init(self: *Paned, window: *Window, direction: input.SplitDirection, label_text: *c.GtkWidget) !void {
    self.* = .{
        .window = window,
        .label_text = label_text,
        .paned = undefined,
        .child1 = .none,
        .child2 = .none,
        .parent = undefined,
    };

    const orientation: c_uint = switch (direction) {
        .right => c.GTK_ORIENTATION_HORIZONTAL,
        .down => c.GTK_ORIENTATION_VERTICAL,
    };

    const paned = c.gtk_paned_new(orientation);
    const gtk_paned: *c.GtkPaned = @ptrCast(paned);
    errdefer c.gtk_widget_destroy(paned);
    self.paned = gtk_paned;
}

pub fn newSurface(self: *Paned, tab: *Tab, parent_: ?*CoreSurface) !*Surface {
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
    c.gtk_widget_set_hexpand(gl_area, 1);
    c.gtk_widget_set_vexpand(gl_area, 1);
    try surface.init(self.window.app, .{
        .window = self.window,
        .tab = tab,
        .parent = .{ .paned = .{
            self,
            .end,
        } },
        .gl_area = @ptrCast(gl_area),
        .title_label = @ptrCast(self.label_text),
        .font_size = font_size,
    });
    return surface;
}

pub fn removeChildren(self: *Paned) void {
    assert(self.child1 != .none);
    assert(self.child2 != .none);
    self.child1 = .none;
    self.child2 = .none;
    c.gtk_paned_set_start_child(@ptrCast(self.paned), null);
    c.gtk_paned_set_end_child(@ptrCast(self.paned), null);
}

pub fn addChild1Surface(self: *Paned, surface: *Surface) void {
    assert(self.child1 == .none);
    self.child1 = Tab.Child{ .surface = surface };
    surface.setParent(Parent{ .paned = .{ self, .start } });
    c.gtk_paned_set_start_child(@ptrCast(self.paned), @ptrCast(surface.gl_area));
}

pub fn addChild2Surface(self: *Paned, surface: *Surface) void {
    assert(self.child2 == .none);
    self.child2 = Tab.Child{ .surface = surface };
    surface.setParent(Parent{ .paned = .{ self, .end } });
    c.gtk_paned_set_end_child(@ptrCast(self.paned), @ptrCast(surface.gl_area));
}

pub fn splitStartPosition(self: *Paned, orientation: c.GtkOrientation) !void {
    _ = orientation;
    _ = self;
    // todo
}

pub fn splitEndPosition(self: *Paned, orientation: c.GtkOrientation) !void {
    _ = orientation;
    _ = self;
    // todo
}
