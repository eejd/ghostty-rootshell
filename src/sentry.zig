const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const sentry = @import("sentry");
const internal_os = @import("os/main.zig");
const state = &@import("global.zig").state;

const log = std.log.scoped(.sentry);

/// Process-wide initialization of our Sentry client.
///
/// PRIVACY NOTE: I want to make it very clear that Ghostty by default does
/// NOT send any data over the network. We use the Sentry native SDK to collect
/// crash reports and logs, but we only store them locally (see Transport).
/// It is up to the user to grab the logs and manually send them to us
/// (or they own Sentry instance) if they want to.
pub fn init(gpa: Allocator) !void {
    // Not supported on Windows currently, doesn't build.
    if (comptime builtin.os.tag == .windows) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const transport = sentry.Transport.init(&Transport.send);
    errdefer transport.deinit();

    const opts = sentry.c.sentry_options_new();
    errdefer sentry.c.sentry_options_free(opts);
    sentry.c.sentry_options_set_release_n(
        opts,
        build_config.version_string.ptr,
        build_config.version_string.len,
    );
    sentry.c.sentry_options_set_transport(opts, @ptrCast(transport));

    // Determine the Sentry cache directory.
    const cache_dir = try internal_os.xdg.cache(alloc, .{ .subdir = "ghostty/sentry" });
    sentry.c.sentry_options_set_database_path_n(
        opts,
        cache_dir.ptr,
        cache_dir.len,
    );

    // Debug logging for Sentry
    sentry.c.sentry_options_set_debug(opts, @intFromBool(true));

    // Initialize
    if (sentry.c.sentry_init(opts) != 0) return error.SentryInitFailed;

    // Setup some basic tags that we always want present
    sentry.setTag("app-runtime", @tagName(build_config.app_runtime));
    sentry.setTag("font-backend", @tagName(build_config.font_backend));
    sentry.setTag("renderer", @tagName(build_config.renderer));

    // Log some information about sentry
    log.debug("sentry initialized database={s}", .{cache_dir});
}

/// Process-wide deinitialization of our Sentry client. This ensures all
/// our data is flushed.
pub fn deinit() void {
    if (comptime builtin.os.tag == .windows) return;

    _ = sentry.c.sentry_close();
}

pub const Transport = struct {
    pub fn send(envelope: *sentry.Envelope, ud: ?*anyopaque) callconv(.C) void {
        _ = ud;
        defer envelope.deinit();

        // Call our internal impl. If it fails there is nothing we can do
        // but log to the user.
        sendInternal(envelope) catch |err| {
            log.warn("failed to persist crash report err={}", .{err});
        };
    }

    /// Implementation of send but we can use Zig errors.
    fn sendInternal(envelope: *sentry.Envelope) !void {
        // If our envelope doesn't have an event then we don't do anything.
        // TODO: figure out how to not encode empty envelopes.

        var arena = std.heap.ArenaAllocator.init(state.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Generate a UUID for this envelope. The envelope DOES have an event_id
        // header but I don't think there is any public API way to get it
        // afaict so we generate a new UUID for the filename just so we don't
        // conflict.
        const uuid = sentry.UUID.init();

        // Get our XDG state directory where we'll store the crash reports.
        // This directory must exist for writing to work.
        const crash_dir = try internal_os.xdg.state(alloc, .{ .subdir = "ghostty/crash" });
        try std.fs.cwd().makePath(crash_dir);

        // Build our final path and write to it.
        const path = try std.fs.path.join(alloc, &.{
            crash_dir,
            try std.fmt.allocPrint(alloc, "{s}.ghosttycrash", .{uuid.string()}),
        });
        log.debug("writing crash report to disk path={s}", .{path});
        try envelope.writeToFile(path);

        log.warn("crash report written to disk path={s}", .{path});
    }
};
