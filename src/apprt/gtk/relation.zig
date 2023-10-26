const Surface = @import("Surface.zig");
const Paned = @import("Paned.zig");
const Tab = @import("Tab.zig");
const c = @import("c.zig");

pub const Position = enum {
    start,
    end,
};

pub const Parent = union(enum) {
    none,
    tab: *Tab,
    paned: struct {
        *Paned,
        Position,
    },
};

pub const Child = union(enum) {
    none,
    surface: *Surface,
    paned: *Paned,

    pub fn setParent(self: Child, parent: Parent) void {
        switch (self) {
            .none => return,
            .surface => |surface| surface.setParent(parent),
            .paned => |paned| paned.setParent(parent),
        }
    }

    pub fn widget(self: Child) ?*c.GtkWidget {
        return switch (self) {
            .none => null,
            .paned => |paned| @ptrCast(@alignCast(paned.paned)),
            .surface => |surface| @ptrCast(surface.gl_area),
        };
    }
};
