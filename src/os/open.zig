const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Open a URL in the default handling application.
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

    try exe.spawn();

    // 50 KiB is the default value used by std.process.Child.run
    try exe.collectOutput(&stdout, &stderr, 50 * 1024);

    _ = try exe.wait();
    if (stderr.items.len > 0) {
        std.log.err("os.open: {s}", .{stderr.items});
    }
}
