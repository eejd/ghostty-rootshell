pub const c = @import("c.zig");
pub usingnamespace @import("init.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
