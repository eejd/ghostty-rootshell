const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const args = @import("args.zig");
const font = @import("../font/main.zig");

const log = std.log.scoped(.list_fonts);

pub const Config = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub fn run(alloc: Allocator) !u8 {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc: Allocator, argsIter: anytype) !u8 {
    var config: Config = .{};
    defer config.deinit();
    try args.parse(Config, alloc, &config, argsIter);

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(
            \\Ghostty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Ghostty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        return 1;
    }

    const stdout = std.io.getStdOut().writer();

    var disco = font.Discover.init();
    defer disco.deinit();

    // Look up all available fonts
    var disco_it = try disco.discover(.{});
    defer disco_it.deinit();
    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;
        const name = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        try stdout.print("{s}\n", .{name});
    }

    return 0;
}
