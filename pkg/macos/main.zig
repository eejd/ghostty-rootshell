pub const foundation = @import("foundation.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
