const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

/// sentry_envelope_t
pub const Envelope = opaque {
    pub fn deinit(self: *Envelope) void {
        c.sentry_envelope_free(@ptrCast(self));
    }

    pub fn writeToFile(self: *Envelope, path: []const u8) !void {
        if (c.sentry_envelope_write_to_file_n(
            @ptrCast(self),
            path.ptr,
            path.len,
        ) != 0) return error.WriteFailed;
    }
};
