const Surface = @import("Surface.zig");
const Paned = @import("Paned.zig");
const Tab = @import("Tab.zig");

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
};
