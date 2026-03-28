//! A pager wraps output to an external pager program (like `less`) when
//! stdout is a TTY. The pager command is determined by `$PAGER`, falling
//! back to `less` if `$PAGER` isn't set.
//!
//! If stdout is not a TTY, writes go directly to stdout.
const Pager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

/// The pager child process, if one was spawned.
child: ?std.process.Child = null,

/// The buffered file writer used for both the pager pipe and direct
/// stdout paths.
file_writer: std.fs.File.Writer = undefined,

/// The write buffer.
buffer: [4096]u8 = undefined,

/// Initialize the pager. If stdout is a TTY, this spawns the pager
/// process. Otherwise, output goes directly to stdout.
pub fn init(alloc: Allocator) Pager {
    return .{ .child = initPager(alloc) };
}

/// Writes to the pager process if available; otherwise, stdout.
pub fn writer(self: *Pager) *std.Io.Writer {
    if (self.child) |child| {
        self.file_writer = child.stdin.?.writer(&self.buffer);
    } else {
        self.file_writer = std.fs.File.stdout().writer(&self.buffer);
    }
    return &self.file_writer.interface;
}

/// Deinitialize the pager. Waits for the spawned process to exit.
pub fn deinit(self: *Pager) void {
    if (self.child) |*child| {
        // Flush any remaining buffered data, close the pipe so the
        // pager sees EOF, then wait for it to exit.
        self.file_writer.interface.flush() catch {};
        if (child.stdin) |stdin| {
            stdin.close();
            child.stdin = null;
        }
        _ = child.wait() catch {};
    }

    self.* = undefined;
}

fn initPager(alloc: Allocator) ?std.process.Child {
    const stdout_file: std.fs.File = .stdout();
    if (!stdout_file.isTty()) return null;

    // Resolve the pager command: $PAGER > "less".
    // An empty $PAGER disables paging.
    const env_result = internal_os.getenv(alloc, "PAGER") catch null;
    const cmd: ?[]const u8 = cmd: {
        const r = env_result orelse break :cmd "less";
        break :cmd if (r.value.len > 0) r.value else null;
    };
    defer if (env_result) |r| r.deinit(alloc);

    if (cmd == null) return null;

    var child: std.process.Child = .init(&.{cmd.?}, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;
    return child;
}

test "pager: non-tty" {
    var pager: Pager = .init(std.testing.allocator);
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
}

test "pager: default writer" {
    var pager: Pager = .{};
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
    const w = pager.writer();
    try w.writeAll("hello");
}
