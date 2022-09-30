pub usingnamespace @import("foundation/array.zig");
pub usingnamespace @import("foundation/dictionary.zig");
pub usingnamespace @import("foundation/string.zig");
pub usingnamespace @import("foundation/type.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
