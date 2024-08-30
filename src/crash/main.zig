//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const sentry_envelope = @import("sentry_envelope.zig");

pub const SentryEnvelope = sentry_envelope.Envelope;

test {
    @import("std").testing.refAllDecls(@This());
}
