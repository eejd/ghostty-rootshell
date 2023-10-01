const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("utf8proc", .{});

    const lib = b.addStaticLibrary(.{
        .name = "utf8proc",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.addIncludePath(upstream.path(""));
    lib.installHeadersDirectoryOptions(.{
        .source_dir = upstream.path(""),
        .install_dir = .header,
        .install_subdir = "",
        .include_extensions = &.{".h"},
    });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.append("-DUTF8PROC_EXPORTS");
    defer flags.deinit();
    for (srcs) |src| {
        lib.addCSourceFile(.{
            .file = upstream.path(src),
            .flags = flags.items,
        });
    }

    b.installArtifact(lib);
}

const srcs: []const []const u8 = &.{
    "utf8proc.c",
};
