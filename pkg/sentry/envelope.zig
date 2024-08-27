const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

/// sentry_envelope_t
pub const Envelope = opaque {
    pub fn deinit(self: *Envelope) void {
        c.sentry_envelope_free(@ptrCast(self));
    }
};
