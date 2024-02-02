pub const c = @import("animation/c.zig");
pub usingnamespace @import("animation/layer.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
