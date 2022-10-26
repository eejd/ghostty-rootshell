const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "objc",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
