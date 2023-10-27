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

    const surface = try self.newSurface(sibling.tab, &sibling.core_surface);
    self.addChild1(.{ .surface = sibling });
    self.addChild2(.{ .surface = surface });
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

pub fn setParent(self: *Paned, parent: Parent) void {
    self.parent = parent;
}

pub fn focusSurfaceInPosition(self: *Paned, position: Position) void {
    const surface: *Surface = self.surfaceInPosition(position) orelse return;
    const widget = @as(*c.GtkWidget, @ptrCast(surface.gl_area));
    _ = c.gtk_widget_grab_focus(widget);
}

pub fn splitSurfaceInPosition(self: *Paned, position: Position, direction: input.SplitDirection) !void {
    const surface: *Surface = self.surfaceInPosition(position) orelse return;

    // Keep explicit reference to surface gl_area before we remove it.
    const object: *c.GObject = @ptrCast(surface.gl_area);
    _ = c.g_object_ref(object);
    defer c.g_object_unref(object);

    // Keep position of divider
    const parent_paned_position_before = c.gtk_paned_get_position(self.paned);
    // Now remove it
    self.removeChildInPosition(position);

    // Create new Paned
    // NOTE: We cannot use `replaceChildInPosition` here because we need to
    // first remove the surface before we create a new pane.
    const paned = try Paned.create(self.window.app.core_app.alloc, self.window, surface, direction);
    switch (position) {
        .start => self.addChild1(.{ .paned = paned }),
        .end => self.addChild2(.{ .paned = paned }),
    }
    // Restore position
    c.gtk_paned_set_position(self.paned, parent_paned_position_before);

    // Focus on new surface
    paned.focusSurfaceInPosition(.end);
}

pub fn replaceChildInPosition(self: *Paned, child: Child, position: Position) void {
    // Keep position of divider
    const parent_paned_position_before = c.gtk_paned_get_position(self.paned);

    // Focus on the sibling, otherwise we'll get a GTK warning
    self.focusSurfaceInPosition(if (position == .start) .end else .start);

    // Now we can remove the other one
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

fn removeChildInPosition(self: *Paned, position: Position) void {
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

fn addChild1(self: *Paned, child: Child) void {
    assert(self.child1 == .none);

    const widget = child.widget() orelse return;
    c.gtk_paned_set_start_child(@ptrCast(self.paned), widget);

    self.child1 = child;
    child.setParent(.{ .paned = .{ self, .start } });
}

fn addChild2(self: *Paned, child: Child) void {
    assert(self.child2 == .none);

    const widget = child.widget() orelse return;
    c.gtk_paned_set_end_child(@ptrCast(self.paned), widget);

    self.child2 = child;
    child.setParent(.{ .paned = .{ self, .end } });
}

fn surfaceInPosition(self: *Paned, position: Position) ?*Surface {
    const child = switch (position) {
        .start => self.child1,
        .end => self.child2,
    };

    return switch (child) {
        .surface => |surface| surface,
        else => null,
    };
}

pub fn deinit(self: *Paned, alloc: Allocator) void {
    switch (self.child1) {
        .none, .surface => {},
        .paned => |paned| {
            paned.deinit(alloc);
            alloc.destroy(paned);
        },
    }

    switch (self.child2) {
        .none, .surface => {},
        .paned => |paned| {
            paned.deinit(alloc);
            alloc.destroy(paned);
        },
    }
}
