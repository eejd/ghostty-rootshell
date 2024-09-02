const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wuffs = b.dependency("wuffs", .{});

    const module = b.addModule("wuffs", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    module.addIncludePath(wuffs.path("release/c"));
    module.addCSourceFile(
        .{
            .file = wuffs.path("release/c/wuffs-v0.4.c"),
            .flags = f: {
                const flags = @import("src/defs.zig").build;
                var a: [flags.len][]const u8 = undefined;
                inline for (flags, 0..) |flag, i| {
                    a[i] = "-D" ++ flag ++ "=1";
                }
                break :f &a;
            },
        },
    );
}
