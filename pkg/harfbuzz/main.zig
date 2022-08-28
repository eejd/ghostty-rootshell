pub const c = @import("c.zig");
pub usingnamespace @import("blob.zig");
pub usingnamespace @import("errors.zig");
pub usingnamespace @import("face.zig");
pub usingnamespace @import("font.zig");
pub usingnamespace @import("version.zig");
pub const Freetype = @import("freetype.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
