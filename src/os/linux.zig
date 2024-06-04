const std = @import("std");
const Allocator = std.mem.Allocator;

/// Returns the path to the cgroup for the given pid.
pub fn cgroupPath(alloc: Allocator, pid: std.os.linux.pid_t) !?[]const u8 {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    // Read our cgroup by opening /proc/<pid>/cgroup and reading the first
    // line. The first line will look something like this:
    // 0::/user.slice/user-1000.slice/session-1.scope
    // The cgroup path is the third field.
    const path = try std.fmt.bufPrint(&buf, "/proc/{}/cgroup", .{pid});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read it all into memory -- we don't expect this file to ever be that large.
    var buf_reader = std.io.bufferedReader(file.reader());
    const contents = try buf_reader.reader().readAllAlloc(
        alloc,
        1 * 1024 * 1024, // 1MB
    );
    defer alloc.free(contents);

    // Find the last ':'
    const idx = std.mem.lastIndexOfScalar(u8, contents, ':') orelse return null;
    const result = std.mem.trimRight(u8, contents[idx + 1 ..], " \r\n");
    return try alloc.dupe(u8, result);
}
