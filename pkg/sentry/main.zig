pub const c = @import("c.zig").c;

const transport = @import("transport.zig");

pub const Envelope = @import("envelope.zig").Envelope;
pub const Level = @import("level.zig").Level;
pub const Transport = transport.Transport;
pub const Value = @import("value.zig").Value;
pub const UUID = @import("uuid.zig").UUID;

pub fn captureEvent(value: Value) ?UUID {
    const uuid: UUID = .{ .value = c.sentry_capture_event(value.value) };
    if (uuid.isNil()) return null;
    return uuid;
}

pub fn setTag(key: []const u8, value: []const u8) void {
    c.sentry_set_tag_n(key.ptr, key.len, value.ptr, value.len);
}

test {
    @import("std").testing.refAllDecls(@This());
}
