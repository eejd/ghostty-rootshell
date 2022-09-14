pub const c = @import("c.zig");
pub usingnamespace @import("init.zig");
pub usingnamespace @import("config.zig");
pub usingnamespace @import("font_set.zig");
pub usingnamespace @import("object_set.zig");
pub usingnamespace @import("pattern.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test {
    _ = @import("test.zig");
}
