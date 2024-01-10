const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const RGBName = @import("rgb_names").RGBName;

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

    inline for (std.meta.fields(RGBName)) |f| {
        const rgb = @field(RGBName, f.name).toRGB();
        try stdout.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{ f.name, rgb.r, rgb.g, rgb.b });
    }

    return 0;
}
