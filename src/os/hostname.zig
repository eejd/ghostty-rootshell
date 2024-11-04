const std = @import("std");
const posix = std.posix;

pub fn bufPrintHostnameFromFileUri(buf: []u8, uri: std.Uri) ![]const u8 {
    // Get the raw string of the URI. Its unclear to me if the various
    // tags of this enum guarantee no percent-encoding so we just
    // check all of it. This isn't a performance critical path.
    const host_component = uri.host orelse return error.NoHostnameInUri;
    const host = switch (host_component) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };

    // When the "Private Wi-Fi address" setting is toggled on macOS the hostname
    // is set to a string of digits separated by a colon, e.g. '12:34:56:78:90:12'.
    // The URI will be parsed as if the last set o digit is a port, so we need to
    // make sure that part is included when it's set.
    if (uri.port) |port| {
        var fbs = std.io.fixedBufferStream(buf);
        std.fmt.format(fbs.writer().any(), "{s}:{d}", .{ host, port }) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            else => unreachable,
        };

        return fbs.getWritten();
    }

    return host;
}

pub fn isLocalHostname(hostname: []const u8) !bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) {
        return true;
    }

    // If hostname is not "localhost" it must match our hostname.
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const ourHostname = posix.gethostname(&buf) catch |err| {
        return err;
    };

    return std.mem.eql(u8, hostname, ourHostname);
}

test "isLocalHostname returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocalHostname("localhost"));
}

test "isLocalHostname returns true when hostname is local" {
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const localHostname = try posix.gethostname(&buf);

    try std.testing.expect(try isLocalHostname(localHostname));
}

test "isLocalHostname returns false when hostname is not local" {
    try std.testing.expectEqual(false, try isLocalHostname("not-the-local-hostname"));
}
