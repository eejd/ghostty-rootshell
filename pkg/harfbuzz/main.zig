pub const c = @import("c.zig");
pub usingnamespace @import("version.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
