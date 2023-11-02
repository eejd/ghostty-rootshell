/// Split represents a surface split where two surfaces are shown side-by-side
/// within the same window either vertically or horizontally.
const Split = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Position = @import("relation.zig").Position;
const Child = @import("relation.zig").Child;
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

/// Our actual GtkPaned widget
paned: *c.GtkPaned,

/// The container for this split panel.
container: Surface.Container,

/// The elements of this split panel.
top_left: Surface.Container.Elem,
bottom_right: Surface.Container.Elem,

/// Create a new split panel with the given sibling surface in the given
/// direction. The direction is where the new surface will be initialized.
///
/// The sibling surface can be in a split already or it can be within a
/// tab. This properly handles updating the surface container so that
/// it represents the new split.
pub fn create(
    alloc: Allocator,
    sibling: *Surface,
    direction: input.SplitDirection,
) !*Split {
    var split = try alloc.create(Split);
    errdefer alloc.destroy(split);
    try split.init(sibling, direction);
    return split;
}

pub fn init(
    self: *Split,
    sibling: *Surface,
    direction: input.SplitDirection,
) !void {
    // Create the new child surface
    const alloc = sibling.app.core_app.alloc;
    var surface = try Surface.create(alloc, sibling.app, .{
        .parent2 = &sibling.core_surface,
    });
    errdefer surface.destroy(alloc);

    // Create the actual GTKPaned, attach the proper children.
    const orientation: c_uint = switch (direction) {
        .right => c.GTK_ORIENTATION_HORIZONTAL,
        .down => c.GTK_ORIENTATION_VERTICAL,
    };
    const paned = c.gtk_paned_new(orientation);
    errdefer c.g_object_unref(paned);

    // Update all of our containers to point to the right place.
    // The split has to point to where the sibling pointed to because
    // we're inheriting its parent. The sibling points to its location
    // in the split, and the surface points to the other location.
    const container = sibling.container;
    sibling.container = .{ .split_tl = &self.top_left };
    surface.container = .{ .split_br = &self.bottom_right };

    self.* = .{
        .paned = @ptrCast(paned),
        .container = container,
        .top_left = .{ .surface = sibling },
        .bottom_right = .{ .surface = surface },
    };

    // Replace the previous containers element with our split.
    // This allows a non-split to become a split, a split to
    // become a nested split, etc.
    container.replace(.{ .split = self });

    // Update our children so that our GL area is properly
    // added to the paned.
    self.updateChildren();
}

/// Focus on first Surface that can be found in given position. If there's a
/// Split in the position, it will focus on the first surface in that position.
pub fn focusFirstSurfaceInPosition(self: *Split, position: Position) void {
    const child = self.childInPosition(position);
    switch (child) {
        .surface => |s| s.grabFocus(),
        .paned => |p| p.focusFirstSurfaceInPosition(position),
        .none => {
            log.warn("attempted to focus on first surface, found none", .{});
            return;
        },
    }
}

/// Split the Surface in the given position into a Split with two surfaces.
pub fn splitSurfaceInPosition(self: *Split, position: Position, direction: input.SplitDirection) !void {
    const surface: *Surface = self.surfaceInPosition(position) orelse return;

    // Keep explicit reference to surface gl_area before we remove it.
    const object: *c.GObject = @ptrCast(surface.gl_area);
    _ = c.g_object_ref(object);
    defer c.g_object_unref(object);

    // Keep position of divider
    const parent_paned_position_before = c.gtk_paned_get_position(self.paned);
    // Now remove it
    self.removeChildInPosition(position);

    // Create new Split
    // NOTE: We cannot use `replaceChildInPosition` here because we need to
    // first remove the surface before we create a new pane.
    const paned = try Split.create(surface.app.core_app.alloc, surface, direction);
    switch (position) {
        .start => self.addChild1(.{ .paned = paned }),
        .end => self.addChild2(.{ .paned = paned }),
    }
    // Restore position
    c.gtk_paned_set_position(self.paned, parent_paned_position_before);

    // Focus on new surface
    paned.focusFirstSurfaceInPosition(.end);
}

/// Replace the existing .start or .end Child with the given new Child.
pub fn replaceChildInPosition(self: *Split, child: Child, position: Position) void {
    // Keep position of divider
    const parent_paned_position_before = c.gtk_paned_get_position(self.paned);

    // Focus on the sibling, otherwise we'll get a GTK warning
    self.focusFirstSurfaceInPosition(if (position == .start) .end else .start);

    // Now we can remove the other one
    self.removeChildInPosition(position);

    switch (position) {
        .start => self.addChild1(child),
        .end => self.addChild2(child),
    }

    // Restore position
    c.gtk_paned_set_position(self.paned, parent_paned_position_before);
}

/// Remove both children, setting *c.GtkSplit start/end children to null.
pub fn removeChildren(self: *Split) void {
    self.removeChildInPosition(.start);
    self.removeChildInPosition(.end);
}

/// Deinit the Split by deiniting its child Split, if they exist.
pub fn deinit(self: *Split, alloc: Allocator) void {
    for ([_]Child{ self.child1, self.child2 }) |child| {
        switch (child) {
            .none, .surface => continue,
            .paned => |paned| {
                paned.deinit(alloc);
                alloc.destroy(paned);
            },
        }
    }
}

fn removeChildInPosition(self: *Split, position: Position) void {
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

// TODO: ehhhhhh
pub fn replace(
    self: *Split,
    ptr: *Surface.Container.Elem,
    new: Surface.Container.Elem,
) void {
    // We can write our element directly. There's nothing special.
    assert(&self.top_left == ptr or &self.bottom_right == ptr);
    ptr.* = new;

    // Update our paned children. This will reset the divider
    // position but we want to keep it in place so save and restore it.
    const pos = c.gtk_paned_get_position(self.paned);
    self.updateChildren();
    c.gtk_paned_set_position(self.paned, pos);
}

/// Update the paned children to represent the current state.
/// This should be called anytime the top/left or bottom/right
/// element is changed.
fn updateChildren(self: *const Split) void {
    c.gtk_paned_set_start_child(
        @ptrCast(self.paned),
        self.top_left.widget(),
    );
    c.gtk_paned_set_end_child(
        @ptrCast(self.paned),
        self.bottom_right.widget(),
    );
}

fn addChild1(self: *Split, child: Child) void {
    assert(self.child1 == .none);

    const widget = child.widget() orelse return;
    c.gtk_paned_set_start_child(@ptrCast(self.paned), widget);

    self.child1 = child;
    child.setParent(.{ .paned = .{ self, .start } });
}

fn addChild2(self: *Split, child: Child) void {
    assert(self.child2 == .none);

    const widget = child.widget() orelse return;
    c.gtk_paned_set_end_child(@ptrCast(self.paned), widget);

    self.child2 = child;
    child.setParent(.{ .paned = .{ self, .end } });
}

fn childInPosition(self: *Split, position: Position) Child {
    return switch (position) {
        .start => self.child1,
        .end => self.child2,
    };
}

fn surfaceInPosition(self: *Split, position: Position) ?*Surface {
    return switch (self.childInPosition(position)) {
        .surface => |surface| surface,
        else => null,
    };
}
