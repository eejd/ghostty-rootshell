const Paned = @import("Paned.zig");
const Tab = @import("Tab.zig");

pub const Position = enum {
    start,
    end,
};

pub const Parent = union(enum) {
    none: void,
    tab: *Tab,
    paned: struct {
        *Paned,
        Position,
    },
};
