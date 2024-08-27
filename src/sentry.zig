const std = @import("std");
const assert = std.debug.assert;
const build_config = @import("build_config.zig");
const sentry = @import("sentry");

const log = std.log.scoped(.sentry);

/// Process-wide initialization of our Sentry client.
///
/// PRIVACY NOTE: I want to make it very clear that Ghostty by default does
/// NOT send any data over the network. We use the Sentry native SDK to collect
/// crash reports and logs, but we only store them locally (see Transport).
/// It is up to the user to grab the logs and manually send them to us
/// (or they own Sentry instance) if they want to.
pub fn init() !void {
    const transport = sentry.Transport.init(&Transport.send);
    errdefer transport.deinit();

    const opts = sentry.c.sentry_options_new();
    errdefer sentry.c.sentry_options_free(opts);
    sentry.c.sentry_options_set_release_n(
        opts,
        build_config.version_string,
        build_config.version_string.len,
    );
    sentry.c.sentry_options_set_transport(opts, @ptrCast(transport));

    // Debug logging for Sentry
    sentry.c.sentry_options_set_debug(opts, @intFromBool(true));

    if (sentry.c.sentry_init(opts) != 0) {
        log.warn("failed to initialize sentry", .{});
    }
}

/// Process-wide deinitialization of our Sentry client. This ensures all
/// our data is flushed.
pub fn deinit() void {
    _ = sentry.c.sentry_close();
}

pub const Transport = struct {
    pub fn send(envelope: *sentry.Envelope, state: ?*anyopaque) callconv(.C) void {
        _ = state;
        defer envelope.deinit();

        log.warn("sending envelope", .{});
    }
};
