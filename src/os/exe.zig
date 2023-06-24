const std = @import("std");
const builtin = @import("builtin");

/// Returns the path to the currently executing executable. This may return
/// null if the path cannot be determined. This function is not thread-safe.
///
/// This function can be very slow. The caller can choose to cache the value
/// if they want but this function itself doesn't handle caching.
pub fn exePath(buf: []u8) !?[]const u8 {
    if (comptime builtin.target.isDarwin()) {
        // We put the path into a temporary buffer first because we need
        // to call realpath on it to resolve symlinks and expand all ".."
        // and such.
        var size: u32 = std.math.cast(u32, buf.len) orelse return error.OutOfMemory;
        const result = _NSGetExecutablePath(buf.ptr, &size);
        if (result == -1) return error.OutOfMemory;
        if (result != 0) return error.Unknown;
        const path = std.mem.sliceTo(buf, 0);

        // Expand.
        var realpath_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const realpath = try std.os.realpath(path, &realpath_buf);
        if (realpath.len > buf.len) return error.OutOfMemory;

        @memcpy(buf[0..realpath.len], realpath);
        return buf[0..realpath.len];
    }

    return null;
}

// https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dyld.3.html
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

test exePath {
    // This just ensures it compiles and runs without crashing. The result
    // is allowed to be null for non-supported platforms.
    var buf: [4096]u8 = undefined;
    _ = try exePath(&buf);
}
