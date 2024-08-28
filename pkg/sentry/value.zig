const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const Level = @import("level.zig").Level;

/// sentry_value_t
pub const Value = struct {
    /// The underlying value. This is a union that could be represented with
    /// an extern union but I don't want to risk C ABI issues so we wrap it
    /// in a struct.
    value: c.sentry_value_t,

    pub fn initMessageEvent(
        level: Level,
        logger: ?[]const u8,
        message: []const u8,
    ) Value {
        return .{ .value = c.sentry_value_new_message_event_n(
            @intFromEnum(level),
            if (logger) |v| v.ptr else null,
            if (logger) |v| v.len else 0,
            message.ptr,
            message.len,
        ) };
    }

    pub fn decref(self: Value) void {
        c.sentry_value_decref(self.value);
    }

    pub fn incref(self: Value) Value {
        c.sentry_value_incref(self.value);
    }

    pub fn isNull(self: Value) bool {
        return c.sentry_value_is_null(self.value) != 0;
    }
};
