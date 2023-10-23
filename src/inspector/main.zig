pub const key = @import("key.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
