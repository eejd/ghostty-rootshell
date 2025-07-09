//! This benchmark tests the throughput of grapheme break calculation.
//! This is a common operation in terminal character printing for terminals
//! that support grapheme clustering.
const Ascii = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    _: Options,
) !*Ascii {
    const ptr = try alloc.create(Ascii);
    errdefer alloc.destroy(ptr);
    return ptr;
}

pub fn destroy(self: *Ascii, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Ascii, writer: anytype, rand: std.Random) !void {
    _ = self;

    var gen: synthetic.Bytes = .{
        .rand = rand,
        .alphabet = synthetic.Bytes.Alphabet.ascii,
    };

    var buf: [1024]u8 = undefined;
    while (true) {
        const data = try gen.next(&buf);
        writer.writeAll(data) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

test Ascii {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Ascii = try .create(alloc, .{});
    defer impl.destroy(alloc);
}
