pub const foundation = @import("foundation.zig");
pub const text = @import("text.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
