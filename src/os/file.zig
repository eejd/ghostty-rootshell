const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.os);

/// This maximizes the number of file descriptors we can have open. We
/// need to do this because each window consumes at least a handful of fds.
/// This is extracted from the Zig compiler source code.
pub fn fixMaxFiles() void {
    if (!@hasDecl(std.os.system, "rlimit")) return;
    const posix = std.os;

    var lim = posix.getrlimit(.NOFILE) catch {
        log.warn("failed to query file handle limit, may limit max windows", .{});
        return; // Oh well; we tried.
    };
    if (comptime builtin.target.isDarwin()) {
        // On Darwin, `NOFILE` is bounded by a hardcoded value `OPEN_MAX`.
        // According to the man pages for setrlimit():
        //   setrlimit() now returns with errno set to EINVAL in places that historically succeeded.
        //   It no longer accepts "rlim_cur = RLIM.INFINITY" for RLIM.NOFILE.
        //   Use "rlim_cur = min(OPEN_MAX, rlim_max)".
        lim.max = @min(std.os.darwin.OPEN_MAX, lim.max);
    }

    // If we're already at the max, we're done.
    if (lim.cur >= lim.max) {
        log.debug("file handle limit already maximized value={}", .{lim.cur});
        return;
    }

    // Do a binary search for the limit.
    var min: posix.rlim_t = lim.cur;
    var max: posix.rlim_t = 1 << 20;
    // But if there's a defined upper bound, don't search, just set it.
    if (lim.max != posix.RLIM.INFINITY) {
        min = lim.max;
        max = lim.max;
    }

    while (true) {
        lim.cur = min + @divTrunc(max - min, 2); // on freebsd rlim_t is signed
        if (posix.setrlimit(.NOFILE, lim)) |_| {
            min = lim.cur;
        } else |_| {
            max = lim.cur;
        }
        if (min + 1 >= max) break;
    }

    log.debug("file handle limit raised value={}", .{lim.cur});
}
