pub const c = @import("foundation/c.zig");
pub usingnamespace @import("foundation/array.zig");
pub usingnamespace @import("foundation/base.zig");
pub usingnamespace @import("foundation/dictionary.zig");
pub usingnamespace @import("foundation/string.zig");
pub usingnamespace @import("foundation/type.zig");
pub usingnamespace @import("foundation/url.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
