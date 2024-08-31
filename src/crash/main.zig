//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const sentry_envelope = @import("sentry_envelope.zig");

pub const sentry = @import("sentry.zig");
pub const Envelope = sentry_envelope.Envelope;

// The main init/deinit functions for global state.
pub const init = sentry.init;
pub const deinit = sentry.deinit;

test {
    @import("std").testing.refAllDecls(@This());
}
