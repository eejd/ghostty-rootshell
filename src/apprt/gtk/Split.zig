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

    // The new surface should always grab focus
    surface.grabFocus();
}

pub fn destroy(self: *Split, alloc: Allocator) void {
    self.top_left.deinit(alloc);
    self.bottom_right.deinit(alloc);

    alloc.destroy(self);
}

/// Remove the top left child.
pub fn removeTopLeft(self: *Split) void {
    self.removeChild(self.top_left, self.bottom_right);
}

/// Remove the top left child.
pub fn removeBottomRight(self: *Split) void {
    self.removeChild(self.bottom_right, self.top_left);
}

// TODO: Is this Zig-y?
inline fn removeChild(self: *Split, remove: Surface.Container.Elem, keep: Surface.Container.Elem) void {
    const window = self.container.window() orelse return;
    const alloc = window.app.core_app.alloc;

    // Keep a reference to the side that we want to keep, so it doesn't get
    // destroyed when it's removed from our underlying GtkPaned.
    const keep_object: *c.GObject = @ptrCast(keep.widget());
    _ = c.g_object_ref(keep_object);
    defer c.g_object_unref(keep_object);

    // Remove our children since we are going to no longer be
    // a split anyways. This prevents widgets with multiple parents.
    self.removeChildren();

    // Our container must become whatever our top left is
    self.container.replace(keep);

    // Grab focus of the left-over side
    keep.grabFocus();

    // TODO: is this correct?
    remove.deinit(alloc);
    alloc.destroy(self);
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
    defer c.gtk_paned_set_position(self.paned, pos);
    self.updateChildren();
}

// grabFocus grabs the focus of the top-left element.
pub fn grabFocus(self: *Split) void {
    self.top_left.grabFocus();
}

/// Update the paned children to represent the current state.
/// This should be called anytime the top/left or bottom/right
/// element is changed.
fn updateChildren(self: *const Split) void {
    // TODO: Not sure we should keep this.
    //
    // We keep references to both widgets, because only Surface widgets have
    // long-held references but GtkPaned will also get destroyed if we don't
    // keep a reference here before removing.
    const top_left_object: *c.GObject = @ptrCast(self.top_left.widget());
    _ = c.g_object_ref(top_left_object);
    defer c.g_object_unref(top_left_object);

    const bottom_right_object: *c.GObject = @ptrCast(self.bottom_right.widget());
    _ = c.g_object_ref(bottom_right_object);
    defer c.g_object_unref(bottom_right_object);

    // We have to set both to null. If we overwrite the pane with
    // the same value, then GTK bugs out (the GL area unrealizes
    // and never rerealizes).
    self.removeChildren();

    // Set our current children
    c.gtk_paned_set_start_child(
        @ptrCast(self.paned),
        self.top_left.widget(),
    );
    c.gtk_paned_set_end_child(
        @ptrCast(self.paned),
        self.bottom_right.widget(),
    );
}

fn removeChildren(self: *const Split) void {
    c.gtk_paned_set_start_child(@ptrCast(self.paned), null);
    c.gtk_paned_set_end_child(@ptrCast(self.paned), null);
}
