pub const c = @import("c.zig");
pub usingnamespace @import("class.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
