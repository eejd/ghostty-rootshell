const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Paned = @import("Paned.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = import("c.zig");

const Child = union(enum) {
    surface: *Surface,
    paned: *Paned,
}

window: *Window,
label_text: *c.GtkLabel,
close_button: *c.GtkButton,
child: Child,

pub fn create(alloc: Allocator, window: *Window) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(paned);
    try tab.init(window);
}

pub fn init(self: *Tab, window) !void {
    self.* = .{
        window = Window,
        label_text = undefined,
        close_button = undefined,
        child = undefined,
    };
    // todo - write the function and initialize everything
}