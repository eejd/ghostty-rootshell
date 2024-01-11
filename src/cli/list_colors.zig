const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const x11_color = @import("../terminal/main.zig").x11_color;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The "list-colors" command is used to list all the named RGB colors in
/// Ghostty.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    inline for (x11_color.map.kvs) |kv| {
        const name = kv.key;
        const rgb = kv.value;
        try stdout.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{ name, rgb.r, rgb.g, rgb.b });
    }

    return 0;
}
