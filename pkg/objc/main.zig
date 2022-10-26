pub const c = @import("c.zig");
pub usingnamespace @import("class.zig");
pub usingnamespace @import("object.zig");
pub usingnamespace @import("sel.zig");

test {
    @import("std").testing.refAllDecls(@This());

    // TODO: remove once we integrate this
    _ = @import("msg_send.zig");
}
