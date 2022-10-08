pub const c = @import("graphics/c.zig");
pub usingnamespace @import("graphics/color_space.zig");
pub usingnamespace @import("graphics/font.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
