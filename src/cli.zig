pub const Action = @import("cli/action.zig").Action;

test {
    @import("std").testing.refAllDecls(@This());
}
