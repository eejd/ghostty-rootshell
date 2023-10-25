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
const Position = @import("relation.zig").Position;
const Parent = @import("relation.zig").Parent;
const Child = @import("relation.zig").Child;
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

/// We'll need to keep a reference to the Window this belongs to for various reasons
window: *Window,

// We keep track of the tab label's text so that if a child widget of this pane
// gets focus (and is a Surface) we can reset the tab label appropriately
label_text: *c.GtkWidget,

/// Our actual GtkPaned widget
paned: *c.GtkPaned,

// We have two children, each of which can be either a Surface, another pane,
// or empty. We're going to keep track of which each child is here.
child1: Child,
child2: Child,

// We also hold a reference to our parent widget, so that when we close we can either
// maximize the parent pane, or close the tab.
parent: Parent,

pub fn create(alloc: Allocator, window: *Window, sibling: *Surface, direction: input.SplitDirection) !*Paned {
    var paned = try alloc.create(Paned);
    errdefer alloc.destroy(paned);
    try paned.init(window, sibling, direction);
    return paned;
}

pub fn init(self: *Paned, window: *Window, sibling: *Surface, direction: input.SplitDirection) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .paned = undefined,
        .child1 = .none,
        .child2 = .none,
        .parent = undefined,
    };
    errdefer self.* = undefined;

    self.label_text = sibling.getTitleLabel() orelse {
        log.warn("sibling surface has no title label", .{});
        return;
    };

    const orientation: c_uint = switch (direction) {
        .right => c.GTK_ORIENTATION_HORIZONTAL,
        .down => c.GTK_ORIENTATION_VERTICAL,
    };

    const paned = c.gtk_paned_new(orientation);
    errdefer c.g_object_unref(paned);

    const gtk_paned: *c.GtkPaned = @ptrCast(paned);
    self.paned = gtk_paned;

    const new_surface = try self.newSurface(sibling.tab, &sibling.core_surface);
    // This sets .parent on each surface
    self.addChild1(.{ .surface = sibling });
    self.addChild2(.{ .surface = new_surface });
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

pub fn focusSurfaceInPosition(self: *Paned, position: Position) void {
    const child = switch (position) {
        .start => self.child1,
        .end => self.child2,
    };

    const surface = switch (child) {
        .surface => |surface| surface,
        else => return,
    };

    const widget = @as(*c.GtkWidget, @ptrCast(surface.gl_area));
    _ = c.gtk_widget_grab_focus(widget);
}

pub fn setParent(self: *Paned, parent: Parent) void {
    self.parent = parent;
}

pub fn replaceChildInPosition(self: *Paned, child: Child, position: Position) void {
    // Keep position of divider
    const parent_paned_position_before = c.gtk_paned_get_position(self.paned);

    self.removeChildInPosition(position);

    switch (position) {
        .start => self.addChild1(child),
        .end => self.addChild2(child),
    }

    // Restore position
    c.gtk_paned_set_position(self.paned, parent_paned_position_before);
}

pub fn removeChildren(self: *Paned) void {
    self.removeChildInPosition(.start);
    self.removeChildInPosition(.end);
}

pub fn removeChildInPosition(self: *Paned, position: Position) void {
    switch (position) {
        .start => {
            assert(self.child1 != .none);
            self.child1 = .none;
            c.gtk_paned_set_start_child(@ptrCast(self.paned), null);
        },
        .end => {
            assert(self.child2 != .none);
            self.child2 = .none;
            c.gtk_paned_set_end_child(@ptrCast(self.paned), null);
        },
    }
}

pub fn addChild1(self: *Paned, child: Child) void {
    assert(self.child1 == .none);

    const parent = Parent{ .paned = .{ self, .start } };
    self.child1 = child;

    switch (child) {
        .none => return,
        .paned => |paned| {
            paned.setParent(parent);
            c.gtk_paned_set_start_child(@ptrCast(self.paned), @ptrCast(@alignCast(paned.paned)));
        },
        .surface => |surface| {
            surface.setParent(parent);
            c.gtk_paned_set_start_child(@ptrCast(self.paned), @ptrCast(surface.gl_area));
        },
    }
}

pub fn addChild2(self: *Paned, child: Child) void {
    assert(self.child2 == .none);

    const parent = Parent{ .paned = .{ self, .end } };
    self.child2 = child;

    switch (child) {
        .none => return,
        .paned => |paned| {
            paned.setParent(parent);
            c.gtk_paned_set_end_child(@ptrCast(self.paned), @ptrCast(@alignCast(paned.paned)));
        },
        .surface => |surface| {
            surface.setParent(parent);
            c.gtk_paned_set_end_child(@ptrCast(self.paned), @ptrCast(surface.gl_area));
        },
    }
}
