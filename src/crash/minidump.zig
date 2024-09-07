const minidump = @import("minidump/minidump.zig");

pub const stream = @import("minidump/stream.zig");
pub const Minidump = minidump.Minidump;

test {
    @import("std").testing.refAllDecls(@This());
}
