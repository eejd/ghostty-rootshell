pub const c = @import("c.zig").c;

test {
    @import("std").testing.refAllDecls(@This());
}
