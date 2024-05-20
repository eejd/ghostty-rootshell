const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
pub fn open(alloc: Allocator, url: []const u8) !void {
    const argv = switch (builtin.os.tag) {
        .linux => &.{ "xdg-open", url },
        .macos => &.{ "open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    var exe = std.process.Child.init(argv, alloc);

    // Pipe stdout/stderr so we can collect output from the command
    exe.stdout_behavior = .Pipe;
    exe.stderr_behavior = .Pipe;
    var stdout = std.ArrayList(u8).init(alloc);
    var stderr = std.ArrayList(u8).init(alloc);
    defer {
        stdout.deinit();
        stderr.deinit();
    }

    // 50 KiB is the default value used by std.process.Child.run
    const output_max_size = 50 * 1024;

    try exe.spawn();
    try exe.collectOutput(&stdout, &stderr, output_max_size);
    _ = try exe.wait();

    // If we have any stderr output we log it. This makes it easier for
    // users to debug why some open commands may not work as expected.
    if (stderr.items.len > 0) std.log.err("open stderr={s}", .{stderr.items});
}
